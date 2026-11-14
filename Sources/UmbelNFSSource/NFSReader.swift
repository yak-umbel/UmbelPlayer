import Darwin
import Foundation
import LibNFS
import UmbelCore

/// A file on an NFS export, read by blocking calls on the thread
/// `UmbelBlockingFileSource` gives it.
///
/// libnfs's own blocking calls have no way to be ended from outside, so its
/// asynchronous interface is used and waited on here in short turns, in which
/// the deadline, a call given up on and the source being stopped are looked at:
/// that is all that ends a wait early.
final class NFSReader: UmbelBlockingFileReader, @unchecked Sendable {
  struct Settings: Sendable {
    var address: NFSAddress
    var userID: Int?
    var groupID: Int?
    var connectTimeout: TimeInterval
    var stallTimeout: TimeInterval
  }

  /// Where a command's callback leaves what it has to say. Kept by the reader,
  /// not by the call, because the library may still call back when a context is
  /// destroyed with commands in flight.
  private final class Reply {
    var isFinished = false
    var status: Int32 = 0
    var data: UnsafeMutableRawPointer?
    var size: UInt64 = 0
    func reset() {
      isFinished = false
      status = 0
      data = nil
      size = 0
    }
  }

  private typealias Callback = @convention(c) (Int32, OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

  private enum Phase { case mount, open, measure, read }

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
  /// What a read is made into: libnfs fills it while a call waits, and the
  /// reader outlives every call.
  private var buffer: UnsafeMutableRawPointer?
  private var bufferSize = 0

  private static let turn: Int32 = 50
  /// How long letting a connection go politely may take.
  private static let goodbye: TimeInterval = 1
  /// NFS version 3, which is what is spoken: libnfs's constant, in a header of
  /// its own that Swift does not see as a number.
  private static let version: Int32 = 3

  private static let callback: Callback = { status, _, data, opaque in
    guard let opaque else { return }
    let reply = Unmanaged<Reply>.fromOpaque(opaque).takeUnretainedValue()
    reply.status = status
    reply.data = data
    reply.isFinished = true
  }

  /// For the measuring, whose data is a structure that is only there while this runs.
  private static let statCallback: Callback = { status, _, data, opaque in
    guard let opaque else { return }
    let reply = Unmanaged<Reply>.fromOpaque(opaque).takeUnretainedValue()
    reply.status = status
    if status == 0, let data { reply.size = data.assumingMemoryBound(to: nfs_stat_64.self).pointee.nfs_size }
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
    guard let made = nfs_init_context() else { throw UmbelError.sourceUnavailable(detail: "NFS could not start") }
    context = made
    configure(made)
    let address = settings.address
    try run(made, .mount, Self.callback) { nfs_mount_async(made, address.host, address.export, $0, $1) }
    try run(made, .open, Self.callback) { nfs_open_async(made, "/" + address.path, O_RDONLY, $0, $1) }
    guard let handle = reply.data else { throw UmbelError.sourceUnavailable(detail: "file could not be opened") }
    file = OpaquePointer(handle)
    try run(made, .measure, Self.statCallback) { nfs_fstat64_async(made, file, $0, $1) }
    length = Int64(clamping: reply.size)
    let size = max(nfs_get_readmax(made), 64 << 10)
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
    let wanted = max(1, min(maxLength, bufferSize))
    try run(context, .read, Self.callback) { nfs_pread_async(context, file, buffer, wanted, UInt64(offset), $0, $1) }
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
        if let file { _ = try? run(context, .read, Self.callback) { nfs_close_async(context, file, $0, $1) } }
        _ = try? run(context, .read, Self.callback) { nfs_umount_async(context, $0, $1) }
      }
      nfs_destroy_context(context)
    }
    context = nil
    file = nil
  }

  // ── Settings ────────────────────────────────────────

  private func configure(_ context: OpaquePointer) {
    _ = nfs_set_version(context, Self.version)
    // A connection that is lost is an error, told to the host, not something
    // to try again for, as the source itself opens a new one when asked.
    nfs_set_autoreconnect(context, 0)
    // Not looking for exports nested under this one, which takes a call (EXPORT)
    // some servers do not answer, and fails the mount if they do not: the export
    // is the one the address names.
    nfs_set_auto_traverse_mounts(context, 0)
    let address = settings.address
    if let port = address.port { nfs_set_nfsport(context, Int32(port)) }
    if let port = address.mountPort { nfs_set_mountport(context, Int32(port)) }
    if let user = settings.userID { nfs_set_uid(context, Int32(truncatingIfNeeded: user)) }
    if let group = settings.groupID { nfs_set_gid(context, Int32(truncatingIfNeeded: group)) }
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
  /// as what the server said if it said something known.
  @discardableResult
  private func run(
    _ context: OpaquePointer, _ phase: Phase, _ callback: @escaping Callback,
    _ start: (@escaping Callback, UnsafeMutableRawPointer) -> Int32
  ) throws -> Int32 {
    reply.reset()
    let opaque = Unmanaged.passUnretained(reply).toOpaque()
    guard start(callback, opaque) == 0 else { throw UmbelError.sourceUnavailable(detail: Self.failure(phase, status: 0)) }
    while !reply.isFinished {
      try check()
      let descriptor = nfs_get_fd(context)
      var entry = pollfd(fd: descriptor, events: Int16(nfs_which_events(context)), revents: 0)
      // No socket yet is a wait for one, which the deadline ends.
      let ready = poll(&entry, descriptor >= 0 ? 1 : 0, Self.turn)
      if ready > 0, nfs_service(context, Int32(entry.revents)) < 0 {
        try check()
        throw UmbelError.sourceUnavailable(detail: reply.isFinished ? Self.failure(phase, status: reply.status) : "connection lost")
      }
    }
    guard reply.status >= 0 else { throw UmbelError.sourceUnavailable(detail: Self.failure(phase, status: reply.status)) }
    return reply.status
  }

  /// What a failed command was, in words that follow no language setting and
  /// carry nothing of the address; the status is minus an errno. libnfs 8.0.0 has
  /// two ways of saying less than the server did, and so these are worded as
  /// what they can be: a mount the server turns away for the export not being
  /// there is told as `EPERM`, as is one it turns away for permission; and a
  /// file that cannot be opened, whatever the server said of the lookup, is told as
  /// `ERANGE`, which libnfs makes of an error it has already made.
  private static func failure(_ phase: Phase, status: Int32) -> String {
    switch (phase, -status) {
    case (.mount, EPERM): return "export not found or not permitted"
    case (_, EACCES), (_, EPERM): return "access denied"
    case (.open, ENOENT): return "file not found"
    case (.open, ERANGE): return "file not found or not readable"
    case (.mount, _): return "mount failed"
    case (.open, _): return "file could not be opened"
    case (.measure, _): return "file could not be measured"
    case (.read, _): return "read failed"
    }
  }
}
