import CoreMedia
import Foundation

/// Output through the system's sample buffer audio renderer, on a render
/// synchronizer that keeps the session's time.
///
/// Sound goes to the system as PCM, decoded here as before; the system
/// spatializes multichannel sound on headphones that can, follows the
/// output device, and keeps the timeline. A session's clock reads that
/// timeline and sets it — starting, pausing, seeking and the rate are the
/// clock's — and the system's display layers join it, so sound and
/// pictures run on one clock. This output only feeds the renderer.
public actor SampleBufferAudioOutput: AudioOutput, PlaybackDiagnosticsReceiving {
  /// The system's timeline this output's renderer plays on.
  internal nonisolated let timeline: any SystemTimeline
  private let makeRenderer: @Sendable (@escaping @Sendable () -> Void) -> any AudioSampleRendering
  private var renderer: (any AudioSampleRendering)?
  /// Samples handed over and not yet played through: handed over again
  /// when the renderer drops what it holds. About a second at most — the
  /// renderer takes no more ahead than that.
  private var handedOver: [(sample: AudioSampleBox, end: CMTime)] = []
  /// Up by one on each flush: a frame waiting for room across one belongs
  /// to before it.
  private var generation = 0
  /// The renderer was replaced since the track was prepared: failing again,
  /// it is reported.
  private var replaced = false
  /// Frames too short for the renderer, held to go joined.
  private var batcher = AudioFrameBatcher()
  /// The level set, if one was: every renderer made takes it. Until one is,
  /// a renderer keeps the level it was made with.
  private var level: (volume: Float, muted: Bool)?
  private var diagnostics: UmbelPlaybackDiagnostics?
  private var lastDiagnosticHost = -Double.infinity

  internal func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) async {
    self.diagnostics = diagnostics
    lastDiagnosticHost = -.infinity
    (renderer as? SystemAudioRenderer)?.setPlaybackDiagnostics(diagnostics)
    await (timeline as? any PlaybackDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics)
  }

  /// On the render synchronizer, which the system player's clock can stand
  /// in for while that plays the sound; see `UmbelObjectAudioMode`.
  public init() {
    self.init(timeline: SwitchableTimeline(base: SynchronizerTimeline())) {
      SystemAudioRenderer(volume: 1, onDiscarded: $0)
    }
  }

  internal init(
    timeline: any SystemTimeline,
    makeRenderer: @escaping @Sendable (@escaping @Sendable () -> Void) -> any AudioSampleRendering
  ) {
    self.timeline = timeline
    self.makeRenderer = makeRenderer
  }

  /// Checks the format has speakers the system knows, and puts a renderer
  /// on the timeline the first time. Frames bring their own format, so a
  /// new track needs nothing more.
  public func prepare(sampleRate: Double, channelCount: Int) async throws {
    _ = try PCMSampleBuffer.format(sampleRate: sampleRate, channelCount: channelCount)
    replaced = false
    if renderer == nil { renderer = try attachedRenderer() }
  }

  public func enqueue(_ frame: AudioFrame) async throws {
    guard frame.frameCount > 0, frame.presentationTime.isValid else { return }
    guard renderer != nil else { throw Self.notPrepared }
    for ready in batcher.add(frame) { try await handOver(ready) }
  }

  private func handOver(_ frame: AudioFrame) async throws {
    let sample = AudioSampleBox(try PCMSampleBuffer.make(frame))
    let asOf = generation
    while let renderer, !renderer.isReadyForMoreMediaData, !renderer.hasFailed {
      // Looked at a hundred times a second: the renderer holds about a
      // second, so the delay costs nothing. Feeding cancelled — a stop or a
      // seek — drops the frame: paused, a full renderer never takes it.
      do {
        try await Task.sleep(nanoseconds: 10_000_000)
      } catch {
        return
      }
      guard generation == asOf else { return }
    }
    guard generation == asOf, var renderer else { return }
    if renderer.hasFailed {
      try await replaceRenderer()
      guard generation == asOf, let fresh = self.renderer else { return }
      renderer = fresh
    }
    renderer.enqueue(sample.buffer)
    keep(sample, until: CMTimeAdd(frame.presentationTime, frame.duration))
    recordOutput("audio_output_queue", renderer: renderer)
  }

  public func flush() async {
    if let renderer { recordOutput("audio_output_flush", renderer: renderer, force: true) }
    generation += 1
    renderer?.flush()
    handedOver.removeAll()
    batcher.reset()
  }

  public func start() async throws {
    guard renderer != nil else { throw Self.notPrepared }
  }

  /// The clock pauses the timeline.
  public func pause() async {}

  public func stop() async {
    await flush()
  }

  /// The clock sets the rate on the timeline; the renderer keeps the pitch.
  public func setRate(_ rate: Double) async {}

  public func setVolume(_ volume: Float, muted: Bool) async {
    level = (volume, muted)
    renderer?.volume = volume
    renderer?.isMuted = muted
  }

  /// None: the clock reads the timeline.
  public var currentAnchor: RenderAnchor? { nil }

  // ── Renderers ───────────────────────────────────────

  private func attachedRenderer() throws -> any AudioSampleRendering {
    let made = makeRenderer { [weak self] in Task { await self?.rendererDiscarded() } }
    (made as? SystemAudioRenderer)?.setPlaybackDiagnostics(diagnostics)
    if let level {
      made.volume = level.volume
      made.isMuted = level.muted
    }
    do {
      try timeline.add(made.queued)
    } catch {
      throw UmbelError.audioOutputUnavailable(
        reason: "the system's timeline would not take the audio renderer: \(error.localizedDescription)")
    }
    return made
  }

  /// Keeps what has not played through, dropping what has.
  private func keep(_ sample: AudioSampleBox, until end: CMTime) {
    let now = timeline.time
    handedOver.removeAll { $0.end <= now }
    handedOver.append((sample, end))
  }

  /// The renderer dropped what it held on its own. Flushed once more here —
  /// the system's advice: a sample handed over while it was being told
  /// would stay, far ahead — and what has not played is handed over again.
  /// The timeline ran on meanwhile: a moment of silence.
  private func rendererDiscarded() {
    guard let renderer else { return }
    renderer.flush()
    handOverAgain(to: renderer)
  }

  private func handOverAgain(to renderer: any AudioSampleRendering) {
    let now = timeline.time
    handedOver.removeAll { $0.end <= now }
    for kept in handedOver { renderer.enqueue(kept.sample.buffer) }
    recordOutput("audio_output_restore", renderer: renderer, force: true)
  }

  private func recordOutput(_ event: String, renderer: any AudioSampleRendering, force: Bool = false) {
    guard let diagnostics else { return }
    let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    guard force || host - lastDiagnosticHost >= 1 else { return }
    if !force { lastDiagnosticHost = host }
    diagnostics.record(event, values: [
      "playhead": timeline.time.seconds, "retainedCount": Double(handedOver.count),
      "firstPTS": handedOver.first.map { CMSampleBufferGetPresentationTimeStamp($0.sample.buffer).seconds } ?? .nan,
      "lastEnd": handedOver.last?.end.seconds ?? .nan,
      "generation": Double(generation), "ready": renderer.isReadyForMoreMediaData ? 1 : 0,
      "failed": renderer.hasFailed ? 1 : 0, "volume": Double(renderer.volume), "muted": renderer.isMuted ? 1 : 0,
    ])
  }

  /// A new renderer in place of one that failed, given what has not played.
  /// Once a track: failing again, it is reported.
  private func replaceRenderer() async throws {
    guard !replaced else {
      throw UmbelError.audioOutputUnavailable(
        reason: "the system's audio renderer failed again: \(renderer?.failure ?? "no reason given")")
    }
    replaced = true
    if let failed = renderer { await timeline.remove(failed.queued) }
    let fresh = try attachedRenderer()
    renderer = fresh
    handOverAgain(to: fresh)
  }

  private static var notPrepared: UmbelError { .audioOutputUnavailable(reason: "not prepared") }
}

/// A sample carried across the output's suspension points. Only the output
/// reads it, and the renderer, which takes calls from any thread.
internal final class AudioSampleBox: @unchecked Sendable {
  let buffer: CMSampleBuffer
  init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}
