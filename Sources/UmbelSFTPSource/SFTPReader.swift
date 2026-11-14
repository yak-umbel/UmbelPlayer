import Darwin
import Foundation
import LibSSH2
import UmbelCore

/// A file read over SFTP by blocking calls, on the thread
/// `UmbelBlockingFileSource` gives it.
///
/// The session is non-blocking, and every wait is a poll of the socket in
/// short turns that look at the deadline, at a call being given up on, and at
/// the source being stopped: libssh2 has no way to be interrupted from
/// outside that is not this.
final class SFTPReader: UmbelBlockingFileReader, @unchecked Sendable {
  struct Settings: Sendable {
    var address: SFTPAddress
    var username: String
    var password: String?
    var privateKeyFile: String?
    var publicKeyFile: String?
    var keyPassphrase: String?
    var connectTimeout: TimeInterval
    var stallTimeout: TimeInterval
    var trust: @Sendable (UmbelSFTPSource.HostKey) -> Bool
  }

  private let settings: Settings
  private let lock = NSLock()
  private var isInterrupted = false
  private var isAbandoned = false
  private var deadline: UInt64 = 0
  private var started = false
  private var descriptor: Int32 = -1
  private var session: OpaquePointer?
  private var sftp: OpaquePointer?
  private var handle: OpaquePointer?
  private var position: Int64 = 0
  private var length: Int64?
  private var isConnecting = false
  /// libssh2 reads ahead only as far as the buffer it is given is large.
  private static let bufferSize = 256 << 10
  private let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)

  private static let turn: Int32 = 50
  /// How long letting a connection go politely may take.
  private static let goodbye: TimeInterval = 1

  init(settings: Settings) { self.settings = settings }

  deinit {
    close()
    buffer.deallocate()
  }

  // ── The calls ───────────────────────────────────────

  func open() throws {
    isConnecting = true
    defer { isConnecting = false }
    try arm(settings.connectTimeout)
    guard libssh2_init(0) == 0 else { throw UmbelError.sourceUnavailable(detail: "SSH could not start") }
    started = true
    try connect()
    guard let made = libssh2_session_init_ex(nil, nil, nil, nil) else {
      throw UmbelError.sourceUnavailable(detail: "SSH could not make a session")
    }
    session = made
    libssh2_session_set_blocking(made, 0)
    try wait { libssh2_session_handshake(made, descriptor) }
    try verifyHostKey(made)
    try authenticate(made)
    try openFile(made)
    position = 0
  }

  func size() -> Int64? { length }

  func read(offset: Int64, maxLength: Int) throws -> Data {
    guard let handle else { throw UmbelError.interrupted }
    try arm(settings.stallTimeout)
    if position != offset {
      libssh2_sftp_seek64(handle, UInt64(offset))
      position = offset
    }
    let wanted = max(1, min(maxLength, Self.bufferSize))
    var count = 0
    try wait {
      let got = libssh2_sftp_read(handle, buffer, wanted)
      if got >= 0 { count = got; return 0 }
      return Int32(got)
    }
    position += Int64(count)
    return Data(bytes: buffer, count: count)
  }

  func abandonCurrentCall() { lock.withLock { isAbandoned = true } }

  func requestInterrupt() { lock.withLock { isInterrupted = true } }

  func close() {
    if let session, !shouldStop {
      // Politely, but not for long: the server may be gone.
      let limit = DispatchTime.now().uptimeNanoseconds &+ UInt64(Self.goodbye * 1_000_000_000)
      func finish(_ step: () -> Int32) {
        while step() == LIBSSH2_ERROR_EAGAIN, !shouldStop, DispatchTime.now().uptimeNanoseconds < limit {
          pollSocket(session)
        }
      }
      if let handle { finish { libssh2_sftp_close_handle(handle) } }
      if let sftp { finish { libssh2_sftp_shutdown(sftp) } }
      finish { libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "") }
    }
    handle = nil
    sftp = nil
    if let session { libssh2_session_free(session) }
    session = nil
    if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    if started { libssh2_exit(); started = false }
  }

  // ── Connecting ──────────────────────────────────────

  private func connect() throws {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var resolved: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(settings.address.host, String(settings.address.port), &hints, &resolved) == 0, let first = resolved else {
      throw UmbelError.sourceUnavailable(detail: "host not found")
    }
    defer { freeaddrinfo(resolved) }
    let made = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
    guard made >= 0 else { throw UmbelError.sourceUnavailable(detail: "no socket") }
    descriptor = made
    var noSignal: Int32 = 1
    setsockopt(made, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(made, F_SETFL, fcntl(made, F_GETFL) | O_NONBLOCK)
    if Darwin.connect(made, first.pointee.ai_addr, first.pointee.ai_addrlen) != 0, errno != EINPROGRESS {
      throw UmbelError.sourceUnavailable(detail: "network error \(errno)")
    }
    while true {
      try check()
      var entry = pollfd(fd: made, events: Int16(POLLOUT), revents: 0)
      if poll(&entry, 1, Self.turn) > 0 {
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(made, SOL_SOCKET, SO_ERROR, &failure, &size)
        if failure != 0 { throw UmbelError.sourceUnavailable(detail: "network error \(failure)") }
        return
      }
    }
  }

  /// The host key is judged by the host's own say-so, and nothing is sent to
  /// the server, not even a name, before it is.
  private func verifyHostKey(_ session: OpaquePointer) throws {
    var length = 0
    var type: Int32 = 0
    guard let key = libssh2_session_hostkey(session, &length, &type),
          let hash = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else {
      throw UmbelError.sourceUnavailable(detail: "no host key")
    }
    let digest = Data(bytes: hash, count: 32)
    let hostKey = UmbelSFTPSource.HostKey(
      type: Self.name(ofKeyType: type), raw: Data(bytes: key, count: length), sha256: digest)
    guard settings.trust(hostKey) else { throw UmbelError.sourceUnavailable(detail: "host key not trusted") }
  }

  private static func name(ofKeyType type: Int32) -> String {
    switch type {
    case LIBSSH2_HOSTKEY_TYPE_RSA: return "ssh-rsa"
    case LIBSSH2_HOSTKEY_TYPE_DSS: return "ssh-dss"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521"
    case LIBSSH2_HOSTKEY_TYPE_ED25519: return "ssh-ed25519"
    default: return "unknown"
    }
  }

  private func authenticate(_ session: OpaquePointer) throws {
    let user = settings.username
    let userLength = UInt32(user.utf8.count)
    if let privateKey = settings.privateKeyFile {
      try wait(failure: "authentication failed") {
        libssh2_userauth_publickey_fromfile_ex(
          session, user, userLength, settings.publicKeyFile, privateKey, settings.keyPassphrase)
      }
    } else if let password = settings.password {
      try wait(failure: "authentication failed") {
        libssh2_userauth_password_ex(session, user, userLength, password, UInt32(password.utf8.count), nil)
      }
    } else {
      throw UmbelError.sourceUnavailable(detail: "no way to authenticate was given")
    }
  }

  private func openFile(_ session: OpaquePointer) throws {
    var made: OpaquePointer?
    try wait(failure: "SFTP could not start") {
      made = libssh2_sftp_init(session)
      return made == nil ? libssh2_session_last_errno(session) : 0
    }
    sftp = made
    guard let made else { throw UmbelError.sourceUnavailable(detail: "SFTP could not start") }
    let path = settings.address.path
    var opened: OpaquePointer?
    try wait(failure: "file could not be opened") {
      opened = libssh2_sftp_open_ex(
        made, path, UInt32(path.utf8.count), UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
      return opened == nil ? libssh2_session_last_errno(session) : 0
    }
    guard let opened else { throw UmbelError.sourceUnavailable(detail: "file could not be opened") }
    handle = opened
    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
    try wait(failure: "file could not be measured") { libssh2_sftp_fstat_ex(opened, &attributes, 0) }
    length = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 ? Int64(attributes.filesize) : nil
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

  /// Calls `body` until libssh2 stops saying it would block, waiting on the
  /// socket between; a negative result is a failure, said as `failure`.
  private func wait(failure: String? = nil, _ body: () -> Int32) throws {
    while true {
      try check()
      let result = body()
      if result == 0 { return }
      guard result == LIBSSH2_ERROR_EAGAIN else {
        throw UmbelError.sourceUnavailable(detail: failure ?? "SSH error \(result)")
      }
      pollSocket(session)
    }
  }

  /// Waits for the socket to be ready in the direction libssh2 is waiting on,
  /// for a turn at most.
  private func pollSocket(_ session: OpaquePointer?) {
    var events: Int16 = 0
    let directions = session.map { libssh2_session_block_directions($0) } ?? LIBSSH2_SESSION_BLOCK_INBOUND
    if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
    if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
    var entry = pollfd(fd: descriptor, events: events, revents: 0)
    _ = poll(&entry, 1, Self.turn)
  }
}
