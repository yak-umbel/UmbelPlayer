import Darwin
import Foundation

/// An RTMP tunnel server for the loopback: RTMP carried in HTTP requests, as
/// `rtmpt` does it, forwarded to a plain RTMP server.
///
/// The client asks `POST /open/1` for a session number, then every request
/// carries what it has to send and brings back what the server has: one byte
/// (how long to wait before asking again) and the bytes. Connections are
/// kept open and each response says how long it is.
final class LoopbackRTMPTunnel: @unchecked Sendable {
  let port: UInt16
  private let upstreamPort: UInt16
  private let listener: Int32
  private let lock = NSLock()
  private var stopped = false
  private var upstream: Int32 = -1

  init(upstreamPort: UInt16) throws {
    self.upstreamPort = upstreamPort
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = LoopbackTCPServer.loopback(port: 0)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener, 8) == 0 else {
      Darwin.close(listener)
      throw POSIXError(.EADDRINUSE)
    }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    self.listener = listener
    self.port = UInt16(bigEndian: assigned.sin_port)
    let thread = Thread { [self] in acceptLoop() }
    thread.name = "loopback.rtmpt"
    thread.start()
  }

  deinit { stop() }

  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    let upstream = self.upstream
    self.upstream = -1
    lock.unlock()
    if !wasStopped { Darwin.close(listener) }
    if upstream >= 0 { Darwin.close(upstream) }
  }

  private var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }

  private func acceptLoop() {
    while !isStopped {
      var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&entry, 1, 50) > 0, entry.revents & Int16(POLLIN) != 0 else { continue }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { return }
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      let thread = Thread { [self] in serve(LoopbackTCPServer.Connection(descriptor: client)) }
      thread.name = "loopback.rtmpt.client"
      thread.start()
    }
  }

  private func serve(_ connection: LoopbackTCPServer.Connection) {
    defer { connection.close() }
    while !isStopped, let head = connection.receiveText(until: "\r\n\r\n", timeout: 30) {
      let lines = head.components(separatedBy: "\r\n")
      let target = (lines.first ?? "").split(separator: " ").dropFirst().first.map(String.init) ?? ""
      let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
      let body = length > 0 ? connection.receiveData(count: length, timeout: 5) : Data()
      guard let body else { return }
      switch target.split(separator: "/").first.map(String.init) ?? "" {
      case "open":
        guard connectUpstream() else {
          connection.send(Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n".utf8))
          return
        }
        respond(connection, Data("1\n".utf8))
      case "send":
        forward(body)
        respond(connection, Data([1]) + collect())
      case "idle":
        respond(connection, Data([1]) + collect())
      case "close":
        respond(connection, Data([1]))
        return
      default:
        connection.send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8))
        return
      }
    }
  }

  private func respond(_ connection: LoopbackTCPServer.Connection, _ body: Data) {
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-fcs\r\nContent-Length: \(body.count)\r\n"
      + "Cache-Control: no-cache\r\nConnection: Keep-Alive\r\n\r\n"
    connection.send(Data(head.utf8) + body)
  }

  private func connectUpstream() -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    var address = LoopbackTCPServer.loopback(port: upstreamPort)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else {
      Darwin.close(descriptor)
      return false
    }
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    lock.lock(); upstream = descriptor; lock.unlock()
    return true
  }

  private var upstreamDescriptor: Int32 {
    lock.lock(); defer { lock.unlock() }
    return upstream
  }

  private func forward(_ data: Data) {
    let descriptor = upstreamDescriptor
    guard descriptor >= 0, !data.isEmpty else { return }
    data.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let count = send(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
        if count <= 0 { return }
        sent += count
      }
    }
  }

  /// What the RTMP server has sent: waits a moment for some, then takes what
  /// is there.
  private func collect() -> Data {
    let descriptor = upstreamDescriptor
    guard descriptor >= 0 else { return Data() }
    var collected = Data()
    var wait: Int32 = 100
    while collected.count < 64 << 10 {
      var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      guard poll(&entry, 1, wait) > 0, entry.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
      var chunk = [UInt8](repeating: 0, count: 16 << 10)
      let count = recv(descriptor, &chunk, chunk.count, 0)
      guard count > 0 else { break }
      collected.append(contentsOf: chunk[0..<count])
      wait = 0
    }
    return collected
  }
}
