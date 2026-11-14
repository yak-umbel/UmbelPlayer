import Darwin
import Foundation

/// An FTP server for the loopback, with one file, `/file`, for sources that
/// make the connection themselves. Passive mode, any number of clients;
/// `REST` and `RETR` give any part of the file.
final class LoopbackFTPServer: @unchecked Sendable {
  struct Behaviour: Sendable {
    var content: Data
    /// The first transfer stops after this many bytes and waits, as a link
    /// that stalls does; later ones are whole.
    var stallFirstTransferAfter: Int?
    /// Accepts connections and says nothing.
    var silent = false
  }

  let port: UInt16
  private let behaviour: Behaviour
  private let listener: Int32
  private let onControlEnd: @Sendable () -> Void
  private let lock = NSLock()
  private var stopped = false
  private var transfers = 0

  init(behaviour: Behaviour, onControlEnd: @escaping @Sendable () -> Void = {}) throws {
    self.behaviour = behaviour
    self.onControlEnd = onControlEnd
    guard let (listener, port) = Self.listenOnLoopback() else { throw POSIXError(.EADDRINUSE) }
    self.listener = listener
    self.port = port
    let thread = Thread { [self] in acceptLoop() }
    thread.name = "loopback.ftp"
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

  private static func listenOnLoopback() -> (Int32, UInt16)? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var yes: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = LoopbackTCPServer.loopback(port: 0)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(descriptor, 8) == 0 else {
      Darwin.close(descriptor)
      return nil
    }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &assigned) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    return (descriptor, UInt16(bigEndian: assigned.sin_port))
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
      thread.name = "loopback.ftp.client"
      thread.start()
    }
  }

  private func serve(_ control: LoopbackTCPServer.Connection) {
    defer {
      control.close()
      onControlEnd()
    }
    if behaviour.silent {
      _ = control.waitForPeerClose(timeout: 10)
      return
    }
    control.send(Data("220 ready\r\n".utf8))
    var restart = 0
    var passive: (descriptor: Int32, port: UInt16)?
    defer { if let passive { Darwin.close(passive.descriptor) } }
    while !isStopped, let line = control.receiveText(until: "\r\n", timeout: 20) {
      let words = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1).map(String.init)
      let command = (words.first ?? "").uppercased()
      let argument = words.count > 1 ? words[1] : ""
      func reply(_ text: String) { control.send(Data((text + "\r\n").utf8)) }
      switch command {
      case "USER": reply("331 password needed")
      case "PASS": reply("230 logged in")
      case "PWD": reply("257 \"/\" is the current directory")
      case "TYPE": reply("200 type set")
      case "SIZE":
        if argument.drop(while: { $0 == "/" }) == "file" { reply("213 \(behaviour.content.count)") } else { reply("550 not found") }
      case "EPSV", "PASV":
        if let old = passive { Darwin.close(old.descriptor) }
        guard let made = Self.listenOnLoopback() else { reply("425 cannot open"); continue }
        passive = made
        if command == "EPSV" {
          reply("229 Entering Extended Passive Mode (|||\(made.1)|)")
        } else {
          reply("227 Entering Passive Mode (127,0,0,1,\(made.1 >> 8),\(made.1 & 0xFF))")
        }
      case "REST":
        restart = Int(argument) ?? 0
        reply("350 restarting")
      case "RETR":
        guard argument.drop(while: { $0 == "/" }) == "file" else { reply("550 not found"); continue }
        guard let channel = passive else { reply("425 no data connection"); continue }
        reply("150 opening data connection")
        transfer(over: channel.descriptor, from: restart)
        reply("226 transfer complete")
        restart = 0
        Darwin.close(channel.descriptor)
        passive = nil
      case "ABOR": reply("226 aborted")
      case "QUIT":
        reply("221 bye")
        return
      default: reply("502 not implemented")
      }
    }
  }

  /// Sends the file from `offset` to the client that connects to `listener`.
  private func transfer(over listener: Int32, from offset: Int) {
    var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&entry, 1, 5_000) > 0 else { return }
    let data = accept(listener, nil, nil)
    guard data >= 0 else { return }
    defer { Darwin.close(data) }
    var noSignal: Int32 = 1
    setsockopt(data, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    lock.lock()
    transfers += 1
    let stallAfter = transfers == 1 ? behaviour.stallFirstTransferAfter : nil
    lock.unlock()
    var position = min(offset, behaviour.content.count)
    while position < behaviour.content.count {
      var end = min(position + 16 << 10, behaviour.content.count)
      if let stallAfter { end = min(end, offset + stallAfter) }
      guard end > position else { break }
      let chunk = behaviour.content.subdata(in: position..<end)
      let sent = chunk.withUnsafeBytes { send(data, $0.baseAddress, $0.count, 0) }
      if sent <= 0 { return }
      position += sent
      if let stallAfter, position >= offset + stallAfter {
        // Stalled: nothing more comes until the client gives up.
        var gone = pollfd(fd: data, events: Int16(POLLIN), revents: 0)
        for _ in 0..<200 {
          if poll(&gone, 1, 50) > 0 {
            var byte: UInt8 = 0
            if recv(data, &byte, 1, 0) <= 0 { return }
          }
          if isStopped { return }
        }
        return
      }
    }
  }
}
