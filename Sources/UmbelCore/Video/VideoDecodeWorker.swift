import Foundation

/// Mutable operations performed only by the owning actor or serial queue.
internal protocol VideoDecodingEngine: AnyObject, Sendable {
  func decode(_ packet: DemuxPacket, hidden: Bool) throws -> [VideoFrame]
  func drain() throws -> [VideoFrame]
  func flush()
  func renew() throws
  func close()
  func setSkipsNonReference(_ skips: Bool)
  /// What it has done since the track was chosen; nil if it does not count.
  var decodingCounts: UmbelDecodingCounts? { get }
  /// What decodes now; nil if it does not say.
  var decoderStatus: UmbelVideoDecoderStatus? { get }
}

extension VideoDecodingEngine {
  var decodingCounts: UmbelDecodingCounts? { nil }
  var decoderStatus: UmbelVideoDecoderStatus? { nil }
}

/// Ownership transfers to this worker at construction. No engine reference
/// escapes, and cleanup runs after an already executing native call finishes.
internal final class VideoDecodeWorker: Sendable {
  private let queue = DispatchQueue(label: "org.umbel.video.decode", qos: .userInitiated)
  private let engine: any VideoDecodingEngine

  init(engine: any VideoDecodingEngine) { self.engine = engine }

  func submit<T: Sendable>(
    generation: VideoDecodeGeneration? = nil,
    _ operation: @escaping @Sendable (any VideoDecodingEngine) throws -> T
  ) -> VideoDecodeResult<T> {
    let result = VideoDecodeResult<T>()
    generation?.register(result)
    queue.async { [engine] in
      guard generation?.isCancelled != true else { result.cancel(); return }
      result.finish(Result { try operation(engine) })
    }
    return result
  }
}

/// Cancellation can arrive outside actor isolation while native decoding is
/// blocked. The lock protects only result ownership, never the native call.
internal final class VideoDecodeGeneration: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var cancellations: [ObjectIdentifier: @Sendable () -> Void] = [:]

  var isCancelled: Bool { lock.withLock { cancelled } }

  func register<T>(_ result: VideoDecodeResult<T>) {
    let cancelNow = lock.withLock {
      guard !cancelled else { return true }
      cancellations[ObjectIdentifier(result)] = { result.cancel() }
      return false
    }
    if cancelNow { result.cancel() }
  }

  func remove<T>(_ result: VideoDecodeResult<T>) {
    _ = lock.withLock { cancellations.removeValue(forKey: ObjectIdentifier(result)) }
  }

  func cancel() {
    let callbacks = lock.withLock {
      cancelled = true
      let callbacks = Array(cancellations.values)
      cancellations.removeAll()
      return callbacks
    }
    callbacks.forEach { $0() }
  }
}

/// Single-consumer completion cell. Cancellation discards even a completed
/// result, so a seek cannot preserve frames that have not yet been consumed.
internal final class VideoDecodeResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Value, Error>?
  private var waiter: CheckedContinuation<Value, Error>?
  private var cancelled = false

  func finish(_ value: Result<Value, Error>) {
    let continuation = lock.withLock {
      guard !cancelled, result == nil else { return nil as CheckedContinuation<Value, Error>? }
      result = value
      let continuation = waiter
      waiter = nil
      return continuation
    }
    continuation?.resume(with: value)
  }

  func cancel() {
    let continuation = lock.withLock {
      cancelled = true
      result = .failure(CancellationError())
      let continuation = waiter
      waiter = nil
      return continuation
    }
    continuation?.resume(throwing: CancellationError())
  }

  func value() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let ready: Result<Value, Error>? = lock.withLock {
        if let result { return result }
        precondition(waiter == nil, "decode result has one consumer")
        waiter = continuation
        return nil
      }
      if let ready { continuation.resume(with: ready) }
    }
  }
}
