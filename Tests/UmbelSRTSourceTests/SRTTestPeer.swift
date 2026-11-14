import Darwin
import Foundation
import LibSRT

/// An SRT peer on the loopback, made with SRT's own interface: it listens,
/// accepts one caller and sends it a payload in messages, as a sender of a
/// live stream does. The source under test is the caller.
final class SRTTestPeer: @unchecked Sendable {
  static let messageSize = 1316

  let port: UInt16
  private let listener: SRTSOCKET
  private let lock = NSLock()
  private var accepted: SRTSOCKET = SRT_INVALID_SOCK
  private var stopped = false
  private var sawPeerGo = false

  /// `passphrase` makes the stream one that is encrypted. After the payload,
  /// with `closeAfterSending` the peer goes; otherwise it keeps the connection
  /// and says nothing, as a sender that has paused does.
  init(payload: Data, passphrase: String? = nil, closeAfterSending: Bool = false, pacing: useconds_t = 1_000) throws {
    _ = srt_startup()
    let socket = srt_create_socket()
    guard socket != SRT_INVALID_SOCK else { throw POSIXError(.EIO) }
    if let passphrase {
      var text = Array(passphrase.utf8CString)
      guard srt_setsockflag(socket, SRTO_PASSPHRASE, &text, Int32(passphrase.utf8.count)) != SRT_ERROR else {
        throw POSIXError(.EINVAL)
      }
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_bind(socket, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound != SRT_ERROR, srt_listen(socket, 2) != SRT_ERROR else { throw POSIXError(.EADDRINUSE) }
    var assigned = sockaddr_in()
    var length = Int32(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { srt_getsockname(socket, $0, &length) }
    }
    listener = socket
    port = UInt16(bigEndian: assigned.sin_port)
    let thread = Thread { [self] in serve(payload: payload, closeAfterSending: closeAfterSending, pacing: pacing) }
    thread.name = "srt.peer"
    thread.start()
  }

  deinit { stop() }

  /// Whether the caller has gone, or has been let go of.
  var callerHasGone: Bool {
    lock.lock(); defer { lock.unlock() }
    return sawPeerGo
  }

  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    let accepted = self.accepted
    lock.unlock()
    guard !wasStopped else { return }
    if accepted != SRT_INVALID_SOCK { srt_close(accepted) }
    srt_close(listener)
    _ = srt_cleanup()
  }

  private var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }

  private func serve(payload: Data, closeAfterSending: Bool, pacing: useconds_t) {
    let caller = srt_accept(listener, nil, nil)
    guard caller != SRT_INVALID_SOCK else { return }
    lock.lock(); accepted = caller; lock.unlock()
    var offset = 0
    while offset < payload.count, !isStopped {
      let end = min(offset + Self.messageSize, payload.count)
      let message = payload.subdata(in: offset..<end)
      let sent = message.withUnsafeBytes { raw in
        srt_sendmsg(caller, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(message.count), -1, 0)
      }
      if sent == SRT_ERROR { break }
      offset = end
      usleep(pacing)
    }
    if closeAfterSending {
      srt_close(caller)
      lock.lock(); sawPeerGo = true; accepted = SRT_INVALID_SOCK; lock.unlock()
      return
    }
    // Quiet, until the caller goes.
    while !isStopped {
      let state = srt_getsockstate(caller)
      if state != SRTS_CONNECTED {
        lock.lock(); sawPeerGo = true; lock.unlock()
        return
      }
      usleep(20_000)
    }
  }
}
