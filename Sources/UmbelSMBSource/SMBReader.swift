import Darwin
import Foundation
import LibSMB2
import UmbelCore

/// A file on an SMB share, read by blocking calls on the thread
/// `UmbelBlockingFileSource` gives it.
///
/// libsmb2's own blocking calls wait a second at a time with no way to be
/// ended from outside, so its asynchronous interface is used and waited on here
/// in short turns, in which the deadline, a call given up on and the source
/// being stopped are looked at: that is all that ends a wait early.
final class SMBReader: UmbelBlockingFileReader, @unchecked Sendable {
  struct Settings: Sendable {
    var address: SMBAddress
    var password: String?
    var domain: String?
    var connectTimeout: TimeInterval
    var stallTimeout: TimeInterval
    var requireEncryption: Bool
  }

  /// What a command's callback leaves for the call that waits on it. Kept by the
  /// reader, not by the call, because the library may still call back when a
  /// context is destroyed with commands in flight.
  private final class Reply {
    var isFinished = false
    var status: Int32 = 0
    var data: UnsafeMutableRawPointer?
    func reset() {
      isFinished = false
      status = 0
      data = nil
    }
  }

  private typealias Callback = @convention(c) (OpaquePointer?, Int32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

  private let settings: Settings
  private let lock = NSLock()
  private var isInterrupted = false
  private var isAbandoned = false
  private var deadline: UInt64 = 0
  private var isConnecting = false
  private let reply = Reply()
  private var context: OpaquePointer?
  private var file: OpaquePointer?
  private var length: Int64?
  /// What a read is made into: libsmb2 fills it while a call waits, and the
  /// reader outlives every call.
  private var buffer: UnsafeMutableRawPointer?
  private var bufferSize = 0

  private static let turn: Int32 = 50
  /// How long letting a connection go politely may take.
  private static let goodbye: TimeInterval = 1
  /// `SMB2_SEC_NTLMSSP`, which libsmb2 keeps in a header of its own that is
  /// not public. The other choice is Kerberos, which this build leaves out.
  private static let ntlm: Int32 = 1

  private static let callback: Callback = { _, status, data, opaque in
    guard let opaque else { return }
    let reply = Unmanaged<Reply>.fromOpaque(opaque).takeUnretainedValue()
    reply.status = status
    reply.data = data
    reply.isFinished = true
  }

  init(settings: Settings) { self.settings = settings }

  deinit {
    close()
    buffer?.deallocate()
  }

  // ── The calls ───────────────────────────────────────

  func open() throws {
    isConnecting = true
    defer { isConnecting = false }
    try arm(settings.connectTimeout)
    guard let made = smb2_init_context() else { throw UmbelError.sourceUnavailable(detail: "SMB could not start") }
    context = made
    configure(made)
    let address = settings.address
    try run(made, failure: "connection failed") {
      smb2_connect_share_async(made, address.server, address.share, address.user ?? "Guest", Self.callback, $0)
    }
    try run(made, failure: "file could not be opened") {
      smb2_open_async(made, address.path, O_RDONLY, Self.callback, $0)
    }
    guard let handle = reply.data else { throw UmbelError.sourceUnavailable(detail: "file could not be opened") }
    file = OpaquePointer(handle)
    var attributes = smb2_stat_64()
    try run(made, failure: "file could not be measured") {
      smb2_fstat_async(made, file, &attributes, Self.callback, $0)
    }
    length = Int64(clamping: attributes.smb2_size)
    let size = Int(max(smb2_get_max_read_size(made), 64 << 10))
    if size > bufferSize {
      buffer?.deallocate()
      buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
      bufferSize = size
    }
  }

  func size() -> Int64? { length }

  func read(offset: Int64, maxLength: Int) throws -> Data {
    guard let context, let file, let buffer else { throw UmbelError.interrupted }
    try arm(settings.stallTimeout)
    let wanted = UInt32(max(1, min(maxLength, bufferSize)))
    try run(context, failure: "read failed") {
      smb2_pread_async(context, file, buffer.assumingMemoryBound(to: UInt8.self), wanted, UInt64(offset), Self.callback, $0)
    }
    // The status of a read is the count, and nothing is an end.
    return Data(bytes: buffer, count: Int(max(0, reply.status)))
  }

  func abandonCurrentCall() { lock.withLock { isAbandoned = true } }

  func requestInterrupt() { lock.withLock { isInterrupted = true } }

  func close() {
    if let context {
      if !shouldStop {
        // Politely, but not for long: the server may be gone.
        let limit = DispatchTime.now().uptimeNanoseconds &+ UInt64(Self.goodbye * 1_000_000_000)
        lock.withLock { deadline = limit }
        if let file { _ = try? run(context, failure: "") { smb2_close_async(context, file, Self.callback, $0) } }
        _ = try? run(context, failure: "") { smb2_disconnect_share_async(context, Self.callback, $0) }
      }
      smb2_destroy_context(context)
    }
    context = nil
    file = nil
  }

  // ── Settings ────────────────────────────────────────

  private func configure(_ context: OpaquePointer) {
    let address = settings.address
    // Signing is offered with a login, and used whenever the server asks for it.
    // A guest session has no key to sign with, and libsmb2 signs it anyway when the
    // dialect is 3.1.1, and the server turns it away for the signatures: a guest
    // is spoken to in SMB 2, where it does not.
    if address.user != nil {
      smb2_set_security_mode(context, UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
      if settings.requireEncryption { smb2_set_seal(context, 1) }
    } else {
      smb2_set_version(context, SMB2_VERSION_ANY2)
    }
    // The login is NTLM, which is what this build has.
    smb2_set_authentication(context, Self.ntlm)
    // Guest: the library's "Guest" user and no password. Never the current
    // user's name, which it would otherwise take.
    smb2_set_user(context, address.user ?? "Guest")
    smb2_set_password(context, settings.password ?? "")
    if let domain = settings.domain { smb2_set_domain(context, domain) }
  }

  // ── Waiting ─────────────────────────────────────────

  private var shouldStop: Bool { lock.withLock { isInterrupted || isAbandoned } }

  private func arm(_ seconds: TimeInterval) throws {
    if lock.withLock({ isInterrupted }) { throw UmbelError.interrupted }
    // A call given up on is that call's alone: the next begins without it.
    lock.withLock {
      isAbandoned = false
      deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, seconds) * 1_000_000_000)
    }
  }

  /// Why a wait ends early, or nothing if it should go on.
  private func check() throws {
    let (interrupted, abandoned, limit) = lock.withLock { (isInterrupted, isAbandoned, deadline) }
    if interrupted || abandoned { throw UmbelError.interrupted }
    if limit != 0, DispatchTime.now().uptimeNanoseconds >= limit {
      throw UmbelError.sourceUnavailable(detail: isConnecting ? "connection timed out" : "no data received")
    }
  }

  /// Starts a command and waits for it; a negative status is a failure, said
  /// as what the server said if it said something, else as `failure`.
  @discardableResult
  private func run(_ context: OpaquePointer, failure: String, _ start: (UnsafeMutableRawPointer) -> Int32) throws -> Int32 {
    reply.reset()
    let opaque = Unmanaged.passUnretained(reply).toOpaque()
    guard start(opaque) == 0 else { throw UmbelError.sourceUnavailable(detail: failure) }
    while !reply.isFinished {
      try check()
      var count = 0
      var timeout: Int32 = -1
      var descriptors: [pollfd] = []
      if let fds = smb2_get_fds(context, &count, &timeout) {
        let events = Int16(smb2_which_events(context))
        descriptors = (0..<count).map { pollfd(fd: fds[$0], events: events, revents: 0) }
      }
      // Waiting to try the next address of the server, which the library
      // asks to be told of when its time is up.
      let turn = timeout >= 0 ? min(Self.turn, timeout) : Self.turn
      let ready = poll(&descriptors, nfds_t(descriptors.count), turn)
      if ready > 0 {
        for entry in descriptors where entry.revents != 0 {
          if smb2_service_fd(context, entry.fd, Int32(entry.revents)) < 0 {
            try check()
            throw UmbelError.sourceUnavailable(detail: reply.isFinished ? failure : "connection lost")
          }
        }
      } else if timeout >= 0, turn == timeout {
        _ = smb2_service_fd(context, -1, 0)
      }
    }
    guard reply.status >= 0 else { throw UmbelError.sourceUnavailable(detail: Self.said(by: context, else: failure)) }
    return reply.status
  }

  /// What the server's status means, in words that follow no language setting
  /// and carry nothing of the address.
  private static func said(by context: OpaquePointer, else failure: String) -> String {
    switch UInt32(bitPattern: smb2_get_nterror(context)) {
    case UInt32(SMB2_STATUS_LOGON_FAILURE), UInt32(SMB2_STATUS_WRONG_PASSWORD), UInt32(SMB2_STATUS_NO_SUCH_USER),
      UInt32(SMB2_STATUS_ACCOUNT_DISABLED), UInt32(SMB2_STATUS_WRONG_PASSWORD_CORE):
      return "authentication failed"
    case UInt32(SMB2_STATUS_ACCESS_DENIED): return "access denied"
    case UInt32(SMB2_STATUS_BAD_NETWORK_NAME): return "share not found"
    case UInt32(SMB2_STATUS_OBJECT_NAME_NOT_FOUND), UInt32(SMB2_STATUS_OBJECT_PATH_NOT_FOUND): return "file not found"
    default: return failure
    }
  }
}
