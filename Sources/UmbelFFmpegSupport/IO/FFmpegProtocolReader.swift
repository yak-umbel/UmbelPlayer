import FFmpeg
import Foundation

/// Reads one address with FFmpeg's own network protocol, as bytes.
///
/// Every call but `requestInterrupt()` blocks, and has to be made from one
/// thread: a thread of the caller's own, not the cooperative pool. Giving up
/// is by the interrupt callback, which FFmpeg polls while it waits; that is
/// what ends a read from outside, and also how the two deadlines are kept —
/// FFmpeg's own timeout options cover a connection that stops answering, but
/// not one that never does.
///
/// Only the protocols named in `Configuration.allowedProtocols` can be
/// opened, whatever the address, or what it redirects to.
public final class FFmpegProtocolReader: FFmpegByteReading, @unchecked Sendable {
  public struct Configuration: Sendable {
    /// What FFmpeg may open, by protocol name: `rtmp` needs `tcp` too.
    public var allowedProtocols: [String]
    /// FFmpeg's own options for the protocol (`ca_file`, `overrun_nonfatal`).
    public var options: [String: String]
    /// How long opening may take, the first exchange with the peer included.
    public var connectTimeout: TimeInterval
    /// How long one read may wait for bytes.
    public var stallTimeout: TimeInterval

    public init(
      allowedProtocols: [String], options: [String: String] = [:],
      connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20
    ) {
      self.allowedProtocols = allowedProtocols
      self.options = options
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
    }
  }

  private static let largestRead = 64 << 10

  private let address: String
  private let configuration: Configuration
  private let state = InterruptState()
  private var context: UnsafeMutablePointer<AVIOContext>?
  private var buffer = [UInt8](repeating: 0, count: FFmpegProtocolReader.largestRead)

  public init(address: String, configuration: Configuration) {
    self.address = address
    self.configuration = configuration
  }

  deinit { close() }

  /// Makes every call now blocked, and every one after, end as `.interrupted`.
  /// Callable from any thread.
  public func requestInterrupt() {
    state.request()
  }

  public func open() throws {
    state.arm(after: configuration.connectTimeout)
    defer { state.disarm() }
    var options: OpaquePointer?
    defer { av_dict_free(&options) }
    av_dict_set(&options, "protocol_whitelist", configuration.allowedProtocols.joined(separator: ","), 0)
    for (name, value) in configuration.options { av_dict_set(&options, name, value, 0) }
    // Copied into what FFmpeg opens; the state it points at is kept here.
    var interrupt = AVIOInterruptCB(
      callback: { opaque in
        guard let opaque else { return 0 }
        return Unmanaged<InterruptState>.fromOpaque(opaque).takeUnretainedValue().shouldInterrupt() ? 1 : 0
      },
      opaque: Unmanaged.passUnretained(state).toOpaque())
    var opened: UnsafeMutablePointer<AVIOContext>?
    let result = avio_open2(&opened, address, AVIO_FLAG_READ, &interrupt, &options)
    guard result >= 0, let opened else { throw state.failure(for: result, during: .connecting) }
    context = opened
  }

  /// Up to `maxLength` bytes, waiting while there are none; empty means the
  /// stream ended.
  public func read(maxLength: Int) throws -> Data {
    guard let context, !state.isRequested else { throw FFmpegStreamFailure.interrupted }
    let wanted = max(1, min(maxLength, Self.largestRead))
    state.arm(after: configuration.stallTimeout)
    defer { state.disarm() }
    let count = buffer.withUnsafeMutableBufferPointer {
      avio_read_partial(context, $0.baseAddress, Int32(wanted))
    }
    if count > 0 { return Data(buffer[0..<Int(count)]) }
    if count == 0 { return Data() }
    if FFmpegErrorCode.classify(count) == .endOfFile, !state.isRequested { return Data() }
    throw state.failure(for: count, during: .receiving)
  }

  /// For a protocol that can be read from anywhere (FTP): the next `read` is
  /// from `offset`. The seek itself may reconnect, within the stall deadline.
  public func seek(to offset: Int64) throws {
    guard let context, !state.isRequested else { throw FFmpegStreamFailure.interrupted }
    state.arm(after: configuration.stallTimeout)
    defer { state.disarm() }
    let result = avio_seek(context, offset, SEEK_SET)
    guard result >= 0 else { throw state.failure(for: Int32(truncatingIfNeeded: result), during: .receiving) }
  }

  /// The whole length, where the protocol knows it; nil where it does not.
  public func knownSize() -> Int64? {
    guard let context else { return nil }
    let size = avio_size(context)
    return size >= 0 ? size : nil
  }

  /// Ends the call now blocked in another thread, and only that: the next
  /// call begins as usual. What the connection was doing is then unknown, and
  /// it is best closed and opened again.
  public func abandonCurrentCall() {
    state.abandon()
  }

  /// Lets the connection go. Not while another thread is in a call.
  public func close() {
    guard context != nil else { return }
    avio_closep(&context)
  }
}
