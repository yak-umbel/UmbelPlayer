import Darwin
import Foundation
import XCTest

/// A UDP relay on loopback between a receiver and a sender, that drops some of
/// the large datagrams — the data — going to the receiver, and nothing else.
/// Everything the receiver sends, the retransmission requests included, goes
/// through as it is.
///
/// The receiver is pointed at `port`; the sender is the one at `target`.
final class UDPLossyRelay: @unchecked Sendable {
  let port: UInt16
  private let facing: Int32      // what the receiver talks to
  private let behind: Int32      // what the sender talks to
  private let target: sockaddr_in
  private let lock = NSLock()
  private var receiver: sockaddr_in?
  private var stopping = false
  private var seen = 0
  private var dropped = 0
  private let everyNth: Int
  private let finished = DispatchSemaphore(value: 0)

  /// Drops every `everyNth` data datagram (those over 600 bytes).
  init(target: UInt16, everyNth: Int) throws {
    self.everyNth = everyNth
    var address = Self.loopback(0)
    let front = socket(AF_INET, SOCK_DGRAM, 0)
    let back = socket(AF_INET, SOCK_DGRAM, 0)
    for descriptor in [front, back] {
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard bound == 0 else {
        Darwin.close(front)
        Darwin.close(back)
        throw XCTSkip("no loopback port")
      }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var named = Self.loopback(0)
    _ = withUnsafeMutablePointer(to: &named) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(front, $0, &length) }
    }
    facing = front
    behind = back
    port = UInt16(bigEndian: named.sin_port)
    self.target = Self.loopback(target)
    let thread = Thread { [self] in run() }
    thread.start()
  }

  var counts: (seen: Int, dropped: Int) { lock.withLock { (seen, dropped) } }

  func stop() {
    lock.withLock { stopping = true }
    finished.wait()
    Darwin.close(facing)
    Darwin.close(behind)
  }

  private func run() {
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while !lock.withLock({ stopping }) {
      var polls = [pollfd(fd: facing, events: Int16(POLLIN), revents: 0), pollfd(fd: behind, events: Int16(POLLIN), revents: 0)]
      guard poll(&polls, 2, 50) > 0 else { continue }
      if polls[0].revents & Int16(POLLIN) != 0 {
        // From the receiver: to the sender, as it is.
        var from = sockaddr_in()
        var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(facing, &buffer, buffer.count, 0, $0, &fromLength) }
        }
        if count > 0 {
          lock.withLock { receiver = from }
          var to = target
          _ = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              sendto(behind, buffer, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
          }
        }
      }
      if polls[1].revents & Int16(POLLIN) != 0 {
        // From the sender: to the receiver, unless it is data that is to be lost.
        let count = recv(behind, &buffer, buffer.count, 0)
        let destination = lock.withLock { receiver }
        if count > 0, var to = destination {
          let drop = lock.withLock { () -> Bool in
            guard count > 600 else { return false }
            seen += 1
            if seen % everyNth == 0 { dropped += 1; return true }
            return false
          }
          if !drop {
            _ = withUnsafePointer(to: &to) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(facing, buffer, count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
              }
            }
          }
        }
      }
    }
    finished.signal()
  }

  private static func loopback(_ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    return address
  }
}
