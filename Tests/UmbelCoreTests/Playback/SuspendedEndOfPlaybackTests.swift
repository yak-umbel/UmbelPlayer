import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class SuspendedEndClock: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds = 0.0
  private var reads = 0
  var now: CMTime {
    lock.lock(); defer { lock.unlock() }
    reads += 1
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }
  var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
  func advance(_ delta: Double) { lock.lock(); seconds += delta; lock.unlock() }
}

private actor SuspendedEndRenderer: VideoRenderer {
  private(set) var count = 0
  private let queue: VideoFrameQueue?
  init(capacity: Int? = nil) {
    queue = capacity.map { VideoFrameQueue(capacity: $0, tolerance: .zero) }
  }
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {
    count += 1
    await queue?.enqueue(frame)
  }
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async { count = 0; await queue?.flush() }
  var queueDepth: Int { get async { await queue?.depth ?? 0 } }
  var totalDroppedFrames: Int { 0 }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

private actor FinalBufferedVideoSource: VideoFrameSource {
  private let frame: VideoFrame
  var skipsNonReference = false
  init(frame: VideoFrame) { self.frame = frame }
  func decode(_ packet: DemuxPacket, hidden: Bool) async throws -> [VideoFrame] { [] }
  func drain() async throws -> [VideoFrame] { [frame, frame] }
  func flush() async {}
  func renew() async throws {}
  func close() async {}
  func setSkipsNonReference(_ skips: Bool) async { skipsNonReference = skips }
}

final class SuspendedEndOfPlaybackTests: XCTestCase {
  private func make(
    mode: UmbelVideoDecodingMode, clock: SuspendedEndClock,
    renderer: SuspendedEndRenderer, output: VirtualAudioOutput?
  ) async throws -> PlaybackSession {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync_check.mp4")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: url), audioOutput: output,
      videoRenderer: renderer, hostTime: clock, videoDecodingMode: mode)
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    return session
  }

  private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<400 {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for playback condition")
  }

  /// After all pictures are handed on, repeated clock reads come from the
  /// EOF watcher. Observing them proves both routed feeders already finished.
  private func waitForPlayoutWatch(
    _ renderer: SuspendedEndRenderer, clock: SuspendedEndClock, frames: Int = 180
  ) async throws {
    try await waitUntil { await renderer.count == frames }
    let reads = clock.readCount
    try await waitUntil { clock.readCount >= reads + 3 }
  }

  func testSuspendedVideoStillEndsAfterAlreadyDrainedAudioPlaysOut() async throws {
    for mode in [UmbelVideoDecodingMode.synchronous, .asynchronous] {
      let clock = SuspendedEndClock()
      let renderer = SuspendedEndRenderer()
      let output = VirtualAudioOutput(hostTime: clock, maxPendingSeconds: 1_000)
      let session = try await make(mode: mode, clock: clock, renderer: renderer, output: output)
      try await waitForPlayoutWatch(renderer, clock: clock)
      let pending = await output.pendingSeconds
      XCTAssertGreaterThanOrEqual(pending, 5.99)
      await session.setVideoSuspended(true)
      let before = await session.phase
      XCTAssertEqual(before, .playing, "queued audio has not played yet")
      clock.advance(7)
      await output.advance(bySeconds: 7)
      await session.refreshClock()
      try await waitUntil { await session.phase == .ended }
      let phase = await session.phase
      let end = await session.currentTime
      XCTAssertEqual(phase, .ended)
      XCTAssertEqual(end.seconds, 6, accuracy: 0.03)
      clock.advance(3)
      let later = await session.currentTime
      XCTAssertEqual(later, end, "the clock stops on the remaining output's end")
      await session.stop()
    }
  }

  func testSuspendingOnlyVideoDoesNotEndAndResumeStillWaitsForPlayout() async throws {
    let clock = SuspendedEndClock()
    let renderer = SuspendedEndRenderer()
    let session = try await make(mode: .asynchronous, clock: clock, renderer: renderer, output: nil)
    try await waitForPlayoutWatch(renderer, clock: clock)
    await session.setVideoSuspended(true)
    clock.advance(1)
    for _ in 0..<10 {
      let phase = await session.phase
      XCTAssertEqual(phase, .playing, "no routed output is not an EOF event")
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    await session.setVideoSuspended(false)
    try await waitForPlayoutWatch(renderer, clock: clock, frames: 150)
    let resumed = await session.phase
    XCTAssertEqual(resumed, .playing, "resumed output must finish its own playout")
    clock.advance(5)
    try await waitUntil { await session.phase == .ended }
    let end = await session.currentTime
    XCTAssertEqual(end.seconds, 6, accuracy: 0.001)
  }
  func testRemovingBackpressuredVideoRearmsAlreadyFinishedAudio() async throws {
    try await exerciseFinishedAudio(replacingAudio: false)
  }

  func testReplacingFinishedAudioWhileVideoIsBackpressuredStillEnds() async throws {
    try await exerciseFinishedAudio(replacingAudio: true)
  }

  func testFinishedAudioDisabledThenReenabledWhileVideoIsBackpressuredStillEnds() async throws {
    try await exerciseFinishedAudio(replacingAudio: true, disablesFirst: true)
  }

  func testReplacingFinishedAudioAfterStopDoesNotRestartFeedingOrEOFWatch() async throws {
    try await exerciseFinishedAudio(replacingAudio: true, stopBeforeReplacing: true)
  }

  private func exerciseFinishedAudio(
    replacingAudio: Bool, disablesFirst: Bool = false, stopBeforeReplacing: Bool = false
  ) async throws {
    let host = SuspendedEndClock()
    let clock = PresentationClock(hostTime: host)
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let renderer = SuspendedEndRenderer(capacity: 1)
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync_check.mp4")
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let audioTrack = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let videoTrack = try XCTUnwrap(tracks.first { $0.kind == .video })
    try await output.prepare(for: audioTrack)
    let audio = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: audioTrack.id))
    addTeardownBlock { await audio.close() }
    let buffer = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(
      width: 4, height: 4, luma: 128, cb: 128, cr: 128))
    let video = FinalBufferedVideoSource(frame: VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 4, height: 4,
      color: VideoColorDescription(matrix: .bt709, range: .limited)))
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: output, videoRenderer: renderer, clock: clock,
      cache: PacketCache(configuration: .init(), measuredTrack: audioTrack.id))
    let audioOnly = PacketRouting(
      audioID: audioTrack.id, audioSession: audio, videoID: nil, videoSession: nil, generation: 0)
    await pipeline.updateRouting(audioOnly)
    addTeardownBlock { await pipeline.stop() }
    try await pipeline.setWantsToPlay(true)
    await pipeline.start()
    try await waitUntil { await output.pendingSeconds >= 5.99 }
    let reads = host.readCount
    try await waitUntil { host.readCount >= reads + 3 }
    // The audio feeder is finished. Add video whose final output cannot fit.
    await pipeline.updateRouting(PacketRouting(
      audioID: audioTrack.id, audioSession: audio,
      videoID: videoTrack.id, videoSession: video, generation: 0))
    try await waitUntil { await renderer.count == 2 }
    let depth = await renderer.queueDepth
    XCTAssertEqual(depth, 1)
    let before = await pipeline.terminal
    XCTAssertNil(before)
    if stopBeforeReplacing { await pipeline.stop() }
    if replacingAudio {
      if disablesFirst {
        await pipeline.updateRouting(PacketRouting(
          audioID: nil, audioSession: nil,
          videoID: videoTrack.id, videoSession: video, generation: 0))
      }
      let replacement = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: audioTrack.id))
      addTeardownBlock { await replacement.close() }
      await pipeline.updateRouting(PacketRouting(
        audioID: audioTrack.id, audioSession: replacement,
        videoID: stopBeforeReplacing ? nil : videoTrack.id, videoSession: video, generation: 0))
      // The old audio task has returned; the new exhausted route must finish too.
      await renderer.flush()
    } else {
      await pipeline.updateRouting(audioOnly)
      await pipeline.suspendVideoFeeding()
    }
    host.advance(7)
    await output.advance(bySeconds: 7)
    if stopBeforeReplacing {
      for _ in 0..<10 {
        let stoppedTerminal = await pipeline.terminal
        XCTAssertNil(stoppedTerminal, "stopped routing must not restart feeding or EOF monitoring")
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      let stoppedDepth = await renderer.queueDepth
      XCTAssertEqual(stoppedDepth, 0)
      return
    }
    try await waitUntil { await pipeline.terminal == .ended }
    let terminal = await pipeline.terminal
    let rate = await clock.rate
    XCTAssertEqual(terminal, .ended)
    XCTAssertEqual(rate, 0)
  }

}
