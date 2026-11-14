import Foundation
import UmbelFFmpegSupport

internal enum AsyncVideoDecodeError: Error { case busy }

/// One-packet lookahead: submitting packet N returns packet N-1's results.
/// The private serial queue can decode N while the consumer presents N-1.
/// This is independent of native codec threading or hardware callback modes.
internal actor AsyncVideoDecodeSession {
  private let worker: VideoDecodeWorker
  private var generation = VideoDecodeGeneration()
  private var pending: VideoDecodeResult<[VideoFrame]>?
  private var consumer: UUID?
  private var transition: UUID?
  private var isClosed = false
  private var hasDrained = false
  internal private(set) var skipsNonReference = false
  internal var isConsuming: Bool { consumer != nil }

  internal init(
    decoder: FFmpegVideoDecoder, baseLayer: UmbelDVBaseLayer? = nil, deinterlacer: VideoDeinterlacer? = nil
  ) {
    worker = VideoDecodeWorker(
      engine: VideoDecodeEngine(decoder: decoder, baseLayer: baseLayer, deinterlacer: deinterlacer))
  }

  internal init(engine: any VideoDecodingEngine) {
    worker = VideoDecodeWorker(engine: engine)
  }

  internal func decode(_ packet: DemuxPacket, hidden: Bool = false) async throws -> [VideoFrame] {
    guard !isClosed else { return [] }
    let owner = try beginConsumption()
    defer { endConsumption(owner) }
    let current = generation
    let previous = pending
    let skipping = skipsNonReference
    pending = worker.submit(generation: current) { engine in
      engine.setSkipsNonReference(skipping)
      return try engine.decode(packet, hidden: hidden)
    }
    guard let previous else { return [] }
    return try await consume(previous, generation: current)
  }

  internal func drain() async throws -> [VideoFrame] {
    guard !isClosed, !hasDrained else { return [] }
    let owner = try beginConsumption()
    defer { endConsumption(owner) }
    hasDrained = true
    let current = generation
    let previous = pending
    pending = nil
    var frames: [VideoFrame] = []
    if let previous { frames = try await consume(previous, generation: current) }
    let drained = worker.submit(generation: current) { try $0.drain() }
    frames += try await consume(drained, generation: current)
    return frames
  }

  internal func flush() async {
    guard !isClosed else { return }
    let operation = beginTransition()
    let result = worker.submit { $0.flush() }
    _ = try? await result.value()
    endTransition(operation)
  }

  /// Read on the decoding queue, after what was handed to it before.
  internal var decodingCounts: UmbelDecodingCounts? {
    get async { (try? await worker.submit { $0.decodingCounts }.value()) ?? nil }
  }

  /// Read on the decoding queue, after what was handed to it before.
  internal var decoderStatus: UmbelVideoDecoderStatus? {
    get async { (try? await worker.submit { $0.decoderStatus }.value()) ?? nil }
  }

  internal func renew() async throws {
    guard !isClosed else { return }
    let operation = beginTransition()
    let result = worker.submit { try $0.renew() }
    defer { endTransition(operation) }
    try await result.value()
  }

  internal func close() async {
    // Repeated closes still await the serial queue: every caller observes
    // completed native cleanup, including during actor reentrancy.
    isClosed = true
    let operation = beginTransition()
    let result = worker.submit { $0.close() }
    _ = try? await result.value()
    endTransition(operation)
  }

  internal func setSkipsNonReference(_ skips: Bool) { skipsNonReference = skips }

  private func beginConsumption() throws -> UUID {
    if Task.isCancelled { generation.cancel(); throw CancellationError() }
    guard consumer == nil, transition == nil else { throw AsyncVideoDecodeError.busy }
    guard !generation.isCancelled else { throw CancellationError() }
    let owner = UUID()
    consumer = owner
    return owner
  }

  private func endConsumption(_ owner: UUID) {
    if consumer == owner { consumer = nil }
  }

  private func consume(
    _ result: VideoDecodeResult<[VideoFrame]>, generation current: VideoDecodeGeneration
  ) async throws -> [VideoFrame] {
    defer { current.remove(result) }
    do {
      let frames = try await withTaskCancellationHandler {
        try await result.value()
      } onCancel: {
        current.cancel()
      }
      guard current === generation, !current.isCancelled else { throw CancellationError() }
      try Task.checkCancellation()
      return frames
    } catch {
      current.cancel()
      throw error
    }
  }

  private func beginTransition() -> UUID {
    generation.cancel()
    generation = VideoDecodeGeneration()
    pending = nil
    consumer = nil
    hasDrained = false
    skipsNonReference = false
    let operation = UUID()
    transition = operation
    return operation
  }

  private func endTransition(_ operation: UUID) {
    if transition == operation { transition = nil }
  }
}
