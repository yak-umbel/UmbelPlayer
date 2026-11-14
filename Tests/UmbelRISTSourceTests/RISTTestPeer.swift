import Darwin
import Foundation
import LibRIST
import XCTest

/// A RIST sender of librist's own, in this process, that waits on a loopback
/// port for the receiver to reach it, and sends numbered payloads: each is a
/// transport stream's seven packets long, begins with its number, and is
/// filled from it, so that what arrives can be checked for being the stream
/// and for losing nothing.
final class RISTTestPeer: @unchecked Sendable {
  static let payloadSize = 1_316

  let port: UInt16
  private var context: OpaquePointer?
  private var logging: UnsafeMutablePointer<rist_logging_settings>?
  private let lock = NSLock()
  private var stopping = false
  private var paused = false
  private var finished = DispatchSemaphore(value: 0)
  private var sender: Thread?
  private var next: UInt64 = 0

  init(
    profile: rist_profile = RIST_PROFILE_MAIN, port: UInt16? = nil, secret: String? = nil, aesBits: Int32 = 128,
    buffer: UInt32 = 100
  ) throws {
    self.port = try port ?? Self.freePort()
    guard rist_logging_set(&logging, RIST_LOG_DISABLE, nil, nil, nil, nil) == 0 else { throw XCTSkip("no logging") }
    var made: OpaquePointer?
    guard rist_sender_create(&made, profile, 0, logging) == 0, let made else { throw XCTSkip("no sender") }
    context = made
    var config: UnsafeMutablePointer<rist_peer_config>?
    guard rist_parse_address2("rist://@127.0.0.1:\(self.port)", &config) == 0, let config else {
      throw XCTSkip("the sender's address was refused")
    }
    var owned: UnsafeMutablePointer<rist_peer_config>? = config
    defer { rist_peer_config_free2(&owned) }
    config.pointee.recovery_length_min = buffer
    config.pointee.recovery_length_max = buffer
    if let secret {
      withUnsafeMutableBytes(of: &config.pointee.secret) { bytes in
        let text = Array(secret.utf8.prefix(bytes.count - 1))
        bytes.copyBytes(from: text)
        bytes[text.count] = 0
      }
      config.pointee.key_size = aesBits
    }
    var peer: OpaquePointer?
    guard rist_peer_create(made, &peer, config) == 0, rist_start(made) == 0 else {
      throw XCTSkip("the sender would not start")
    }
  }

  deinit { stop() }

  /// Sends a payload each `interval` seconds, from the number after the last sent, until paused or stopped.
  func send(every interval: TimeInterval = 0.004) {
    lock.withLock { paused = false }
    guard sender == nil else { return }
    let thread = Thread { [self] in
      while !lock.withLock({ stopping }) {
        if !lock.withLock({ paused }), let context {
          let number = lock.withLock { () -> UInt64 in
            defer { next += 1 }
            return next
          }
          let payload = Self.payload(number)
          payload.withUnsafeBytes { bytes in
            var block = rist_data_block()
            block.payload = bytes.baseAddress
            block.payload_len = bytes.count
            block.ts_ntp = 0
            block.virt_src_port = UInt16.max
            _ = rist_sender_data_write(context, &block)
          }
        }
        Thread.sleep(forTimeInterval: interval)
      }
      finished.signal()
    }
    sender = thread
    thread.start()
  }

  /// The connection stays; nothing more is sent.
  func pause() { lock.withLock { paused = true } }

  func stop() {
    let thread = lock.withLock { () -> Thread? in
      stopping = true
      return sender
    }
    if thread != nil { finished.wait() }
    sender = nil
    if let context { rist_destroy(context) }
    context = nil
    if logging != nil { rist_logging_settings_free2(&logging) }
  }

  // ── What is sent, and checking what arrived ─────────

  static func payload(_ number: UInt64) -> Data {
    var data = Data(count: payloadSize)
    for index in 0..<8 { data[index] = UInt8(truncatingIfNeeded: number >> UInt64(56 - 8 * index)) }
    for index in 8..<payloadSize { data[index] = UInt8(truncatingIfNeeded: number &+ UInt64(index)) }
    return data
  }

  /// The numbers of the payloads `stream` holds, whole and from the first
  /// byte; nil where it is anything else.
  static func numbers(in stream: Data) -> [UInt64]? {
    guard stream.count % payloadSize == 0 else { return nil }
    var found: [UInt64] = []
    for start in stride(from: 0, to: stream.count, by: payloadSize) {
      let block = stream.subdata(in: start..<start + payloadSize)
      let number = block.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      guard block == payload(number) else { return nil }
      found.append(number)
    }
    return found
  }

  private static func freePort() throws -> UInt16 {
    for _ in 0..<50 {
      let made = socket(AF_INET, SOCK_DGRAM, 0)
      defer { Darwin.close(made) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(made, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
      guard bound == 0 else { continue }
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(made, $0, &length) }
      }
      let port = UInt16(bigEndian: address.sin_port)
      return port
    }
    throw XCTSkip("no loopback port")
  }
}
