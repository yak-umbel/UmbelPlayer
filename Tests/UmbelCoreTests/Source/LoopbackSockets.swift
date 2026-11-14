import Darwin
import Foundation

/// A TCP peer on the loopback, on a thread of its own, for sources that read
/// the network themselves and so cannot be given a stub.
///
/// It accepts one connection and runs `script` on it. Blocking sockets on a
/// thread of the server's own: the code under test never shares an execution
/// context with it.
final class LoopbackTCPServer: @unchecked Sendable {
  final class Connection: @unchecked Sendable {
    fileprivate let descriptor: Int32
    /// Bytes received and not yet handed on by `receiveText`.
    private var received = Data()
    /// Closed once: a descriptor number closed twice may by then be another
    /// socket's.
    private var isClosed = false

    init(descriptor: Int32) { self.descriptor = descriptor }

    /// What the peer has sent up to and including `terminator`, or nil when
    /// it closed, or nothing complete came within `timeout`.
    func receiveText(until terminator: String, timeout: TimeInterval) -> String? {
      let marker = Data(terminator.utf8)
      let end = Date().addingTimeInterval(timeout)
      while Date() < end {
        if let range = received.range(of: marker) {
          let text = String(decoding: received[received.startIndex..<range.upperBound], as: UTF8.self)
          received.removeSubrange(received.startIndex..<range.upperBound)
          return text
        }
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 50) >= 0 else { return nil }
        guard entry.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = recv(descriptor, &chunk, chunk.count, 0)
        if count > 0 { received.append(contentsOf: chunk[0..<count]) } else if count == 0 { return nil }
        else if errno != EAGAIN && errno != EINTR { return nil }
      }
      return nil
    }

    func send(_ data: Data) {
      data.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
          let count = Darwin.send(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
          if count <= 0 { return }
          sent += count
        }
      }
    }

    /// Exactly `count` bytes from the peer, or nil if it closed, or they did not
    /// all come within `timeout`.
    func receiveData(count: Int, timeout: TimeInterval) -> Data? {
      let end = Date().addingTimeInterval(timeout)
      while received.count < count, Date() < end {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 50) >= 0 else { return nil }
        guard entry.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { continue }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let got = recv(descriptor, &chunk, chunk.count, 0)
        if got > 0 { received.append(contentsOf: chunk[0..<got]) } else if got == 0 { return nil }
        else if errno != EAGAIN && errno != EINTR { return nil }
      }
      guard received.count >= count else { return nil }
      let data = Data(received.prefix(count))
      received.removeFirst(count)
      return data
    }

    /// True once the other side has closed, or reset, within `timeout`.
    func waitForPeerClose(timeout: TimeInterval) -> Bool {
      let end = Date().addingTimeInterval(timeout)
      var byte = UInt8(0)
      while Date() < end {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, 50) >= 0 else { return true }
        if entry.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
          let count = recv(descriptor, &byte, 1, 0)
          if count == 0 { return true }
          if count < 0 && errno != EAGAIN && errno != EINTR { return true }
        }
      }
      return false
    }

    /// Closes so the other side's next read fails rather than ends: a reset.
    func reset() {
      var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
      setsockopt(descriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
      close()
    }

    func close() {
      guard !isClosed else { return }
      isClosed = true
      Darwin.close(descriptor)
    }
  }

  let port: UInt16
  private let listener: Int32
  private let lock = NSLock()
  private var stopped = false

  init(script: @escaping @Sendable (Connection) -> Void) throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = Self.loopback(port: 0)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(listener, 4) == 0 else {
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
    let thread = Thread { [self] in serve(script) }
    thread.name = "loopback.tcp"
    thread.start()
  }

  deinit { stop() }

  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    lock.unlock()
    if !wasStopped { Darwin.close(listener) }
  }

  private var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }

  private func serve(_ script: @Sendable (Connection) -> Void) {
    while !isStopped {
      var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      guard poll(&entry, 1, 50) > 0, entry.revents & Int16(POLLIN) != 0 else { continue }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { return }
      // A peer that has gone is told by an error, not by a signal that ends
      // the whole process: a source gives up before the server has finished.
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
      let connection = Connection(descriptor: client)
      script(connection)
      connection.close()
      return
    }
  }

  static func loopback(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
    return address
  }

  /// A port nothing listens on: bound to learn one, then let go.
  static func unusedPort(type: Int32) -> UInt16 {
    let descriptor = socket(AF_INET, type, 0)
    defer { Darwin.close(descriptor) }
    var address = loopback(port: 0)
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    return UInt16(bigEndian: assigned.sin_port)
  }
}

/// Sends datagrams to a port on the loopback, one every few milliseconds,
/// each filled with its own number: a reader that joins late still gets whole
/// datagrams, and can tell which.
final class LoopbackDatagramSender: @unchecked Sendable {
  static let size = 1316

  private let lock = NSLock()
  private var stopped = false

  init(port: UInt16) {
    let thread = Thread { [self] in
      let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
      defer { Darwin.close(descriptor) }
      var address = LoopbackTCPServer.loopback(port: port)
      var number: UInt8 = 1
      while !isStopped {
        let payload = [UInt8](repeating: number, count: Self.size)
        _ = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(descriptor, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
        number = number == 250 ? 1 : number + 1
        usleep(5_000)
      }
    }
    thread.name = "loopback.udp"
    thread.start()
  }

  deinit { stop() }

  func stop() {
    lock.lock(); stopped = true; lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }
}
