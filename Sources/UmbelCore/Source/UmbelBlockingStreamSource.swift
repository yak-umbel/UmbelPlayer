import Foundation
import UmbelFFmpegSupport

/// A live stream read by blocking calls: what a module that brings a network
/// library of its own writes, to be made a source by `UmbelBlockingStreamSource`.
///
/// Every call but `requestInterrupt()` is made from one thread, a thread of
/// the source's own, so blocking it harms nothing. Failures are thrown as
/// `UmbelError` and reach the host as they are: no address, which commonly
/// holds a token, in any of them.
public protocol UmbelBlockingByteReader: AnyObject, Sendable {
  /// Connects, and says why it could not. Called once.
  func open() throws
  /// Up to `maxLength` bytes, waiting while there are none; empty means the
  /// stream ended where it was meant to. A stream that is lost is an error,
  /// not an end.
  func read(maxLength: Int) throws -> Data
  /// Makes the call now blocked, and every one after, end by throwing
  /// `UmbelError.interrupted`. Called from any thread, and not again after
  /// `close()`.
  func requestInterrupt()
  /// Lets the connection go: once, after the last call. Also after an `open()`
  /// that failed.
  func close()
}

/// A live stream from a reader that blocks, as bytes read once and in order:
/// the session reports it cannot seek.
///
/// The reader runs on a thread of its own, into a bounded buffer. A read that
/// is cancelled gives up and nothing more: the stream goes on for the next.
/// A stream that fails stays failed — the source does not connect again, and
/// the host decides whether to open it again.
public actor UmbelBlockingStreamSource: UmbelStreamingSource {
  private let pump: NetworkStreamPump
  private var isInvalidated = false

  /// Nothing is opened until the first read.
  public init(reader: any UmbelBlockingByteReader) {
    self.init(pump: NetworkStreamPump(reader: BlockingReaderBridge(reader), queue: LiveByteQueue()))
  }

  init(pump: NetworkStreamPump) {
    self.pump = pump
  }

  /// Released without being invalidated: the connection still goes.
  deinit { pump.stop() }

  /// A live stream has no length.
  public var contentLength: Int64? { nil }

  public func readNext(maxLength: Int) async throws -> Data {
    guard !isInvalidated, !Task.isCancelled else { throw UmbelError.interrupted }
    guard maxLength > 0 else { return Data() }
    pump.startIfNeeded()
    switch await pump.queue.take(maxLength: maxLength) {
    case .data(let data): return data
    case .end: return Data()
    case .failure(let error): throw error
    // Cancelled: only this read gives up, the stream goes on.
    case .woken: throw UmbelError.interrupted
    }
  }

  public func invalidate() async {
    isInvalidated = true
    pump.stop()
  }
}

/// Lets the pump, which reads FFmpeg's streams, read a module's: what it
/// throws is already the host's to read.
private final class BlockingReaderBridge: FFmpegByteReading, @unchecked Sendable {
  private let reader: any UmbelBlockingByteReader

  init(_ reader: any UmbelBlockingByteReader) { self.reader = reader }

  func requestInterrupt() { reader.requestInterrupt() }
  func open() throws { try reader.open() }
  func read(maxLength: Int) throws -> Data { try reader.read(maxLength: maxLength) }
  func close() { reader.close() }
}
