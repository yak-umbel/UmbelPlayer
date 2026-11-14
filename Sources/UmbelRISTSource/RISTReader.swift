import Darwin
import Foundation
import LibRIST
import UmbelCore

/// RIST, read by blocking calls on the thread `UmbelBlockingStreamSource`
/// gives it.
///
/// The library runs its own threads and hands the payloads over through a
/// queue, which is waited on a turn at a time: between turns the deadline and
/// the host's stop are looked at, which is all that ends a wait early.
final class RISTReader: UmbelBlockingByteReader, @unchecked Sendable {
  private let address: RISTAddress
  private let profile: UmbelRISTSource.Profile
  private let connectTimeout: TimeInterval
  private let stallTimeout: TimeInterval
  private let lock = NSLock()
  private var isInterrupted = false
  private var context: OpaquePointer?
  private var logging: UnsafeMutablePointer<rist_logging_settings>?
  /// What the last payload held that was not asked for yet.
  private var pending = Data()
  private var hasData = false
  private var deadline: UInt64 = 0

  /// The length of one wait for a payload, in milliseconds.
  private static let turn: Int32 = 100

  init(address: RISTAddress, profile: UmbelRISTSource.Profile, connectTimeout: TimeInterval, stallTimeout: TimeInterval) {
    self.address = address
    self.profile = profile
    self.connectTimeout = connectTimeout
    self.stallTimeout = stallTimeout
  }

  deinit { close() }

  func open() throws {
    if lock.withLock({ isInterrupted }) { throw UmbelError.interrupted }
    // Nothing the library says is kept: its wording follows no language
    // setting and may carry the address.
    guard rist_logging_set(&logging, RIST_LOG_DISABLE, nil, nil, nil, nil) == 0 else {
      throw UmbelError.sourceUnavailable(detail: "RIST could not start")
    }
    var made: OpaquePointer?
    guard rist_receiver_create(&made, profile.library, logging) == 0, let made else {
      throw UmbelError.sourceUnavailable(detail: "RIST could not start")
    }
    context = made
    // Only the host and the port are given to the library to read; the rest is set on what
    // it makes of them, as values.
    var config: UnsafeMutablePointer<rist_peer_config>?
    let host = address.host.contains(":") ? "[\(address.host)]" : address.host
    guard rist_parse_address2("rist://\(host):\(address.port)", &config) == 0, let config else {
      throw UmbelError.sourceUnavailable(detail: "RIST refused the address")
    }
    var owned: UnsafeMutablePointer<rist_peer_config>? = config
    defer { rist_peer_config_free2(&owned) }
    apply(address, to: config)
    var peer: OpaquePointer?
    guard rist_peer_create(made, &peer, config) == 0 else {
      throw UmbelError.sourceUnavailable(detail: "RIST refused the settings")
    }
    guard rist_start(made) == 0 else { throw UmbelError.sourceUnavailable(detail: "RIST could not start") }
    arm(connectTimeout)
  }

  func read(maxLength: Int) throws -> Data {
    // The first payload is waited for from the connect deadline; each one after,
    // from when it is asked for, not from when the last was taken: a consumer that
    // is slow is not a sender that is silent.
    if hasData { arm(stallTimeout) }
    while true {
      try check()
      if !pending.isEmpty {
        let part = pending.prefix(maxLength)
        pending.removeFirst(part.count)
        return Data(part)
      }
      guard let current = context else { throw UmbelError.interrupted }
      var block: UnsafeMutablePointer<rist_data_block>?
      let count = rist_receiver_data_read2(current, &block, Self.turn)
      if count < 0 { throw UmbelError.sourceUnavailable(detail: "RIST read failed") }
      guard count > 0, let block else { continue }
      defer { var owned: UnsafeMutablePointer<rist_data_block>? = block; rist_receiver_data_block_free2(&owned) }
      hasData = true
      if let payload = block.pointee.payload, block.pointee.payload_len > 0 {
        pending = Data(bytes: payload, count: block.pointee.payload_len)
      }
    }
  }

  func requestInterrupt() { lock.withLock { isInterrupted = true } }

  func close() {
    if let context { rist_destroy(context) }
    context = nil
    // After the context, which holds the pointer.
    if logging != nil { rist_logging_settings_free2(&logging) }
    pending = Data()
  }

  // ── Deadlines ───────────────────────────────────────

  private func arm(_ seconds: TimeInterval) {
    lock.withLock { deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, seconds) * 1_000_000_000) }
  }

  private func check() throws {
    let (interrupted, limit) = lock.withLock { (isInterrupted, deadline) }
    if interrupted { throw UmbelError.interrupted }
    if limit != 0, DispatchTime.now().uptimeNanoseconds >= limit {
      throw UmbelError.sourceUnavailable(detail: hasData ? "no data received" : "connection timed out")
    }
  }

  // ── Settings ────────────────────────────────────────

  private func apply(_ address: RISTAddress, to config: UnsafeMutablePointer<rist_peer_config>) {
    let numbers = address.numbers
    func number(_ name: String, _ set: (Int) -> Void) { if let value = numbers[name] { set(value) } }
    number("buffer") {
      config.pointee.recovery_length_min = UInt32($0)
      config.pointee.recovery_length_max = UInt32($0)
    }
    number("buffer-min") { config.pointee.recovery_length_min = UInt32($0) }
    number("buffer-max") { config.pointee.recovery_length_max = UInt32($0) }
    number("reorder-buffer") { config.pointee.recovery_reorder_buffer = UInt32($0) }
    number("rtt-min") { config.pointee.recovery_rtt_min = UInt32($0) }
    number("rtt-max") { config.pointee.recovery_rtt_max = UInt32($0) }
    number("bandwidth") { config.pointee.recovery_maxbitrate = UInt32($0) }
    number("return-bandwidth") { config.pointee.recovery_maxbitrate_return = UInt32($0) }
    number("aes-type") { config.pointee.key_size = Int32($0) }
    number("key-rotation") { config.pointee.key_rotation = UInt32($0) }
    number("compression") { config.pointee.compression = Int32($0) }
    number("virt-dst-port") { config.pointee.virt_dst_port = UInt16($0) }
    number("session-timeout") { config.pointee.session_timeout = UInt32($0) }
    number("keepalive-interval") { config.pointee.keepalive_interval = UInt32($0) }
    number("congestion-control") {
      config.pointee.congestion_control_mode = rist_congestion_control_mode(rawValue: UInt32($0))
    }
    number("timing-mode") { config.pointee.timing_mode = rist_timing_mode(rawValue: UInt32($0)) }
    number("min-retries") { config.pointee.min_retries = UInt32($0) }
    number("max-retries") { config.pointee.max_retries = UInt32($0) }
    if let secret = address.secret { Self.copy(secret, into: &config.pointee.secret) }
    if let cname = address.cname { Self.copy(cname, into: &config.pointee.cname) }
  }

  /// Text into a C array of the library's, cut to fit with its terminator.
  private static func copy<T>(_ text: String, into field: inout T) {
    withUnsafeMutableBytes(of: &field) { bytes in
      let source = Array(text.utf8.prefix(bytes.count - 1))
      bytes.copyBytes(from: source)
      bytes[source.count] = 0
    }
  }
}
