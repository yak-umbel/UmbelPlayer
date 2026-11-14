import CoreMedia
import Foundation

/// One bounded transition to a compatible base layer or native compressed display.
/// The last GOP is replayed; arbitrary dependent packets never start a decoder.
internal actor VideoPath: VideoFrameSource {
  private var source: any VideoFrameSource
  private let fallback: @Sendable () async throws -> any VideoFrameSource
  private let fallbackPlan: VideoPresentationPlan
  private let observation: VideoPresentationObservation?
  private let prepare: @Sendable (VideoPresentationPlan) async throws -> Void
  private let resumeTime: @Sendable () async -> CMTime
  private var gop: [(packet: DemuxPacket, hidden: Bool)] = []
  private var retainedBytes = 0
  private var usingFallback = false
  private var awaitingKeyframe = false
  private var waitingPackets = 0
  private var closed = false
  private var generation: UInt64 = 0
  private var lastReturned: CMTime = .invalid
  private var pending: [VideoFrame] = []
  private var skipping = false
  private var drained = false
  private var transitioning = false
  private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
  private var compressedCutoff = CMTime.invalid
  private var fallsBackToCompressed: Bool { fallbackPlan.route == .systemCompressed }

  init(primary: any VideoFrameSource,
       fallback: @escaping @Sendable () async throws -> any VideoFrameSource,
       fallbackPlan: VideoPresentationPlan, observation: VideoPresentationObservation?,
       prepare: @escaping @Sendable (VideoPresentationPlan) async throws -> Void,
       resumeTime: @escaping @Sendable () async -> CMTime = { .invalid }) {
    source = primary
    self.fallback = fallback
    self.fallbackPlan = fallbackPlan
    self.observation = observation
    self.prepare = prepare
    self.resumeTime = resumeTime
  }

  func decode(_ packet: DemuxPacket, hidden: Bool) async throws -> [VideoFrame] {
    guard !closed else { return [] }
    let before = generation
    await waitForTransition()
    guard before == generation, !closed else { return [] }
    try Task.checkCancellation()
    if usingFallback, !fallsBackToCompressed, let changed = packet.decoderParameters?.dovi,
       !changed.hasBaseLayer || ![1, 2, 4, 6].contains(changed.compatibility) {
      throw UmbelError.unsupportedDynamicHDR("no compatible base layer after format change")
    }
    if !usingFallback {
      if packet.isKeyframe { gop.removeAll(keepingCapacity: true); retainedBytes = 0 }
      if packet.isKeyframe || !gop.isEmpty {
        if retainedBytes + packet.data.count <= 16 * 1024 * 1024, gop.count < 512 {
          gop.append((packet, hidden)); retainedBytes += packet.data.count
        } else { gop.removeAll(); retainedBytes = 0 }
      }
    }
    if awaitingKeyframe {
      waitingPackets += 1
      guard waitingPackets <= 512 else {
        throw UmbelError.videoRenderUnavailable(reason: "no random access point for video recovery")
      }
      guard packet.isKeyframe else { return [] }
      awaitingKeyframe = false
      waitingPackets = 0
    }
    let ready = pending
    pending.removeAll(keepingCapacity: true)
    do {
      let frames = try await source.decode(packet, hidden: hidden || hidesCompressed(packet))
      guard before == generation, !closed else { return [] }
      return record(ready + frames)
    } catch {
      guard before == generation, !closed else { return [] }
      guard !usingFallback, case UmbelError.videoRenderUnavailable = error else { throw error }
      if case UmbelError.videoRenderUnavailable(let reason) = error { observation?.noteSystemFailure(reason) }
      return record(try await recover())
    }
  }

  private func recover() async throws -> [VideoFrame] {
    guard !usingFallback, !closed else { return [] }
    // A new no-base-layer configuration must never be fed to the fallback.
    if !fallsBackToCompressed, let latest = gop.last?.packet.decoderParameters?.dovi,
       !latest.hasBaseLayer || ![1, 2, 4, 6].contains(latest.compatibility) {
      throw UmbelError.unsupportedDynamicHDR("no compatible base layer after format change")
    }
    usingFallback = true
    transitioning = true
    defer { finishTransition() }
    generation &+= 1
    let transition = generation
    let replay = gop
    gop.removeAll(); retainedBytes = 0
    await source.close()
    let replacement = try await fallback()
    guard !closed else { await replacement.close(); return [] }
    source = replacement
    await source.setSkipsNonReference(skipping)
    guard !closed else { return [] }
    try await prepare(fallbackPlan)
    guard !closed else { return [] }
    observation?.select(fallbackPlan)
    if generation != transition {
      await source.flush()
      awaitingKeyframe = true
      return []
    }
    guard replay.first?.packet.isKeyframe == true else { awaitingKeyframe = true; return [] }
    let cutoff = await resumeTime()
    guard !closed else { return [] }
    guard generation == transition else {
      await source.flush()
      awaitingKeyframe = true
      return []
    }
    if fallsBackToCompressed { compressedCutoff = cutoff }
    var result: [VideoFrame] = []
    for entry in replay {
      result += try await source.decode(entry.packet, hidden: entry.hidden || hidesCompressed(entry.packet))
      guard !closed else { return [] }
      if generation != transition {
        await source.flush()
        awaitingKeyframe = true
        return []
      }
    }
    return result.filter {
      $0.compressedSample != nil || !cutoff.isNumeric || !$0.presentationTime.isNumeric || $0.presentationTime >= cutoff
    }
  }

  /// Later decode-order packets can still precede the resume point. Keep
  /// every dependency, but suppress its display until the next flush.
  private func hidesCompressed(_ packet: DemuxPacket) -> Bool {
    fallsBackToCompressed && compressedCutoff.isNumeric && packet.presentationTime.isNumeric
      && packet.presentationTime < compressedCutoff
  }

  func recoverDisplayFailure(_ error: Error) async throws -> Bool {
    let before = generation
    await waitForTransition()
    guard before == generation else { return false }
    guard !usingFallback, !closed, !drained, case UmbelError.videoRenderUnavailable = error else { return false }
    pending = try await recover()
    return true
  }

  private func record(_ frames: [VideoFrame]) -> [VideoFrame] {
    for frame in frames where frame.presentationTime.isNumeric {
      if !lastReturned.isNumeric || frame.presentationTime > lastReturned { lastReturned = frame.presentationTime }
    }
    return frames
  }

  func drain() async throws -> [VideoFrame] {
    guard !closed else { return [] }
    let before = generation
    await waitForTransition()
    guard before == generation, !closed else { return [] }
    let ready = pending
    pending.removeAll()
    do {
      let frames = try await source.drain()
      guard before == generation, !closed else { return [] }
      drained = true
      return record(ready + frames)
    } catch {
      guard before == generation, !closed else { return [] }
      guard !usingFallback, case UmbelError.videoRenderUnavailable = error else { throw error }
      if case UmbelError.videoRenderUnavailable(let reason) = error { observation?.noteSystemFailure(reason) }
      let replayed = try await recover()
      guard !awaitingKeyframe else { throw UmbelError.videoRenderUnavailable(reason: "no random access point at end of stream") }
      let tail = try await source.drain()
      drained = true
      return record(ready + replayed + tail)
    }
  }
  func flush() async {
    generation &+= 1
    gop.removeAll(); retainedBytes = 0; pending.removeAll(); lastReturned = .invalid
    compressedCutoff = .invalid
    drained = false
    waitingPackets = 0
    if transitioning { await waitForTransition(); return }
    transitioning = true
    defer { finishTransition() }
    await source.flush()
  }
  func renew() async throws { await flush(); try await source.renew() }
  func close() async { closed = true; await flush(); await source.close() }
  func setSkipsNonReference(_ skips: Bool) async { skipping = skips; await source.setSkipsNonReference(skips) }
  var skipsNonReference: Bool { skipping }
  var decodingCounts: UmbelDecodingCounts? { get async { await source.decodingCounts } }
  var decoderStatus: UmbelVideoDecoderStatus? { get async { await source.decoderStatus } }

  private func waitForTransition() async {
    guard transitioning else { return }
    await withCheckedContinuation { transitionWaiters.append($0) }
  }
  private func finishTransition() {
    transitioning = false
    let waiting = transitionWaiters
    transitionWaiters.removeAll()
    for waiter in waiting { waiter.resume() }
  }

  /// Renderer refusal belongs to the same bounded fallback transaction.
  static func deliver(_ frame: VideoFrame, to renderer: any VideoRenderer,
                      source: (any VideoFrameSource)?, validate: @Sendable () async throws -> Void) async throws -> Bool {
    do { try await renderer.enqueue(frame); return false }
    catch {
      try await validate()
      guard let path = source as? VideoPath, try await path.recoverDisplayFailure(error) else { throw error }
      try await validate()
      return true
    }
  }
}
