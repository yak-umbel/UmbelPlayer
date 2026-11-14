import Darwin
import Foundation
import LibSRT
import UmbelCore

/// SRT, read by blocking calls on the thread `UmbelBlockingStreamSource`
/// gives it.
///
/// Giving up is by closing the socket from another thread, which SRT answers
/// by ending the call that waits on it. Both deadlines are SRT's own socket
/// options: the connection one for connecting, the receive one for every wait
/// for a message after.
final class SRTReader: UmbelBlockingByteReader, @unchecked Sendable {
  private let address: SRTAddress
  private let connectTimeout: TimeInterval
  private let stallTimeout: TimeInterval
  private let lock = NSLock()
  private var socket: SRTSOCKET = SRT_INVALID_SOCK
  private var isStarted = false
  private var isInterrupted = false

  /// The most a message of a live stream holds: a transport stream's seven
  /// packets, the size SRT sets by default.
  private static let largestMessage = 1_500

  init(address: SRTAddress, connectTimeout: TimeInterval, stallTimeout: TimeInterval) {
    self.address = address
    self.connectTimeout = connectTimeout
    self.stallTimeout = stallTimeout
  }

  deinit { close() }

  func open() throws {
    try lock.withLock {
      if isInterrupted { throw UmbelError.interrupted }
      guard srt_startup() != SRT_ERROR else { throw UmbelError.sourceUnavailable(detail: "SRT could not start") }
      isStarted = true
      // The library writes warnings and errors to standard error on its own,
      // a few lines a second on a live stream, to an app that never asked.
      // What went wrong reaches the host as the error thrown, not as that.
      srt_setloglevel(LOG_CRIT)
    }
    let made = srt_create_socket()
    guard made != SRT_INVALID_SOCK else { throw UmbelError.sourceUnavailable(detail: "SRT could not make a socket") }
    // Held from here, so that giving up can close it while it connects.
    let interrupted = lock.withLock { () -> Bool in
      if isInterrupted { return true }
      socket = made
      return false
    }
    if interrupted {
      srt_close(made)
      throw UmbelError.interrupted
    }
    try configure(made)
    var resolved: UnsafeMutablePointer<addrinfo>?
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM
    guard getaddrinfo(address.host, String(address.port), &hints, &resolved) == 0, let first = resolved else {
      throw failure()
    }
    defer { freeaddrinfo(resolved) }
    guard srt_connect(made, first.pointee.ai_addr, Int32(first.pointee.ai_addrlen)) != SRT_ERROR else {
      throw failure(socket: made)
    }
  }

  func read(maxLength: Int) throws -> Data {
    var buffer = [CChar](repeating: 0, count: Self.largestMessage)
    while true {
      let current = lock.withLock { socket }
      if lock.withLock({ isInterrupted }) || current == SRT_INVALID_SOCK { throw UmbelError.interrupted }
      let count = srt_recvmsg(current, &buffer, Int32(buffer.count))
      if count > 0 { return Data(bytes: buffer, count: Int(count)) }
      // An empty message, which a live stream does not have: asked again.
      if count == 0 { continue }
      throw failure(socket: current)
    }
  }

  func requestInterrupt() {
    let toClose = lock.withLock { () -> SRTSOCKET in
      isInterrupted = true
      let open = socket
      socket = SRT_INVALID_SOCK
      return open
    }
    if toClose != SRT_INVALID_SOCK { srt_close(toClose) }
  }

  func close() {
    let (toClose, started) = lock.withLock { () -> (SRTSOCKET, Bool) in
      let open = socket
      socket = SRT_INVALID_SOCK
      let wasStarted = isStarted
      isStarted = false
      return (open, wasStarted)
    }
    if toClose != SRT_INVALID_SOCK { srt_close(toClose) }
    if started { _ = srt_cleanup() }
  }

  // ── Options ─────────────────────────────────────────

  private func configure(_ socket: SRTSOCKET) throws {
    func set<T>(_ option: SRT_SOCKOPT, _ value: T) throws {
      var copy = value
      guard srt_setsockflag(socket, option, &copy, Int32(MemoryLayout<T>.size)) != SRT_ERROR else {
        throw UmbelError.sourceUnavailable(detail: "SRT refused an option")
      }
    }
    func setText(_ option: SRT_SOCKOPT, _ text: String) throws {
      let bytes = Array(text.utf8)
      guard srt_setsockflag(socket, option, bytes, Int32(bytes.count)) != SRT_ERROR else {
        throw UmbelError.sourceUnavailable(detail: "SRT refused an option")
      }
    }
    try set(SRTO_CONNTIMEO, Int32(max(1, connectTimeout * 1_000)))
    try set(SRTO_RCVTIMEO, Int32(max(1, stallTimeout * 1_000)))
    if let latency = address.latency { try set(SRTO_LATENCY, Int32(latency)) }
    if let streamID = address.streamID { try setText(SRTO_STREAMID, streamID) }
    if let passphrase = address.passphrase { try setText(SRTO_PASSPHRASE, passphrase) }
  }

  // ── What went wrong ─────────────────────────────────

  /// Said without the address, which carries tokens, or the passphrase, and
  /// without SRT's own wording, which follows no language setting.
  private func failure(socket: SRTSOCKET? = nil) -> UmbelError {
    if lock.withLock({ isInterrupted }) { return .interrupted }
    var system: Int32 = 0
    let code = srt_getlasterror(&system)
    switch code {
    // The wait for a message ended: by the receive timeout, as a blocking
    // read's does, or as a read that would block.
    case Int32(SRT_ETIMEOUT.rawValue), Int32(SRT_EASYNCRCV.rawValue):
      return .sourceUnavailable(detail: "no data received")
    case Int32(SRT_ENOSERVER.rawValue):
      return .sourceUnavailable(detail: "connection timed out")
    case Int32(SRT_ECONNREJ.rawValue):
      let reason = socket.map { srt_getrejectreason($0) } ?? 0
      return .sourceUnavailable(detail: "connection rejected (reason \(reason))")
    default:
      return .sourceUnavailable(detail: "network error \(code)")
    }
  }
}
