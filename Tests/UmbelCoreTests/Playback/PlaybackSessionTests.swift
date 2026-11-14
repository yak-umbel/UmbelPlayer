import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class FakeHostTime: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    defer { lock.unlock() }
    seconds += delta
  }
}

/// A local file behind a source that reads in order only, standing in for a
/// live stream without needing one.
private actor SequentialOnlySource: UmbelStreamingSource {
  private let data: Data
  private var position = 0

  init(url: URL) throws { self.data = try Data(contentsOf: url) }

  var contentLength: Int64? { nil }

  func readNext(maxLength: Int) async throws -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func invalidate() async {}
}

/// A renderer that also follows the clock, as the sample buffer one does;
/// it only records what the clock told it.
private final class FollowingRenderer: VideoRenderer, ClockFollower, @unchecked Sendable {
  private let lock = NSLock()
  private var rates: [Double] = []

  var heardRates: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return rates
  }

  func clockDidChange(anchor: RenderAnchor, rate: Double) {
    lock.lock()
    rates.append(rate)
    lock.unlock()
  }

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { get async { .zero } }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

private enum Fixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }
}

final class PlaybackSessionTests: XCTestCase {
  func testAFileCanBeSeekedOnceLoadedAndNotAfterStopping() async throws {
    let session = PlaybackSession(source: try UmbelFileSource(url: Fixture.url("seek_grid.mp4")))
    var seekable = await session.isSeekable
    XCTAssertFalse(seekable, "nothing is open before load()")
    try await session.load()
    seekable = await session.isSeekable
    XCTAssertTrue(seekable)
    await session.stop()
    seekable = await session.isSeekable
    XCTAssertFalse(seekable, "a stopped session seeks nowhere")
  }

  func testAStreamReadOnlyInOrderCannotBeSeeked() async throws {
    let session = PlaybackSession(source: try SequentialOnlySource(url: Fixture.url("live_like.ts")))
    try await session.load()
    addTeardownBlock { await session.stop() }
    let seekable = await session.isSeekable
    XCTAssertFalse(seekable)
  }

  func testLoadExposesTracksAndDuration() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: FakeHostTime()),
      hostTime: FakeHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }

    let tracks = await session.tracks
    XCTAssertEqual(tracks.filter { $0.kind == .audio }.count, 1)
    let duration = await session.duration
    XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.3)
  }

  func testAudioContentMakesClockAuthorityAudio() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: FakeHostTime()),
      hostTime: FakeHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    let authority = await session.clockAuthority
    XCTAssertEqual(authority, .audio)
  }

  func testVideoOnlyContentFallsBackToHostAuthority() async throws {
    // short.mp4 has a video track only, no audio.
    let source = try UmbelFileSource(url: Fixture.url("short.mp4"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: FakeHostTime()),
      hostTime: FakeHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    let authority = await session.clockAuthority
    XCTAssertEqual(authority, .host, "without sound it falls back to the host clock")
  }

  func testAudioDelayDoesNotExtendVideoOnlyPlayback() async throws {
    let host = FakeHostTime()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: Fixture.url("short.mp4")),
      audioOutput: VirtualAudioOutput(hostTime: host),
      videoRenderer: FollowingRenderer(), hostTime: host)
    addTeardownBlock { await session.stop() }
    await session.setAudioDelay(1)
    try await session.load()
    try await session.play()
    let duration = await session.duration
    try await Task.sleep(nanoseconds: 100_000_000)

    host.advance(seconds: duration.seconds + 0.1)
    for _ in 0..<100 {
      if await session.phase == .ended { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .ended)
  }

  func testPlaybackAdvancesCurrentTime() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    // Let feeding put some audio into the output first.
    try await Task.sleep(nanoseconds: 200_000_000)

    host.advance(seconds: 0.5)
    await output.advance(bySeconds: 0.5)
    await session.refreshClock()

    let time = await session.currentTime
    XCTAssertGreaterThan(time.seconds, 0.4)
    XCTAssertLessThan(time.seconds, 0.7)
  }

  func testPauseFreezesCurrentTime() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await Task.sleep(nanoseconds: 200_000_000)

    host.advance(seconds: 0.5)
    await output.advance(bySeconds: 0.5)
    await session.refreshClock()
    await session.pause()
    let before = await session.currentTime

    host.advance(seconds: 10)
    let after = await session.currentTime
    XCTAssertEqual(after.seconds, before.seconds, accuracy: 0.0001, "paused, time does not move on")
  }

  func testSeekJumpsClock() async throws {
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 1.0, preferredTimescale: 600))
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 1.0, accuracy: 0.05, "after a seek the clock jumps")
  }

  /// A seek the content cannot take — a live stream's — is refused, and
  /// playing carries on as it was: it does not end in failure.
  func testASeekTheContentCannotTakeLeavesPlayingAlone() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: try SequentialOnlySource(url: Fixture.url("hls/main0")),
      audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await waitUntilPlaying(session)
    host.advance(seconds: 0.5)
    await output.advance(bySeconds: 0.5)
    await session.refreshClock()
    let before = await session.currentTime

    do {
      try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
      XCTFail("this content cannot seek")
    } catch let error as UmbelError {
      guard case .seekUnsupported = error else { return XCTFail("\(error)") }
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .playing)
    host.advance(seconds: 0.3)
    await output.advance(bySeconds: 0.3)
    await session.refreshClock()
    let after = await session.currentTime
    XCTAssertEqual(after.seconds, before.seconds + 0.3, accuracy: 0.05)
  }

  /// A renderer that follows the clock is told of its changes with no
  /// wiring by the host: the session connects it.
  func testARendererThatFollowsTheClockIsConnected() async throws {
    let renderer = FollowingRenderer()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: Fixture.url("sync_check.mp4")),
      videoRenderer: renderer, hostTime: FakeHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await waitUntilPlaying(session)
    XCTAssertTrue(renderer.heardRates.contains(1))
  }

  /// End to end: pictures decoded from a real file really reach the renderer
  /// and become pixels.
  ///
  /// Watching can only judge sync; a failure like "the window is black"
  /// belongs here. The fixture's first frame is white, so the pixels read
  /// back after presenting are bright.
  func testVideoFramesRenderToVisiblePixels() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("sync_check.mp4"))
    // No audio output: this test asks only whether the video chain gets
    // through, so the clock falls back to the host clock.
    let session = PlaybackSession(source: source, videoRenderer: renderer, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    // Wait for feeding to decode the first frames into the renderer.
    try await Task.sleep(nanoseconds: 300_000_000)
    let depth = await renderer.queueDepth
    XCTAssertGreaterThan(depth, 0, "decoded frames did not reach the renderer")

    let rendered = try await session.renderVideoFrame()
    let presented = try XCTUnwrap(rendered, "there is a frame to present where the clock starts")
    XCTAssertEqual(presented.presentationTime.seconds, 0, accuracy: 0.05)

    let pixel = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertGreaterThan(Int(pixel.r), 180, "the fixture starts white, so what is drawn is bright")
    XCTAssertGreaterThan(Int(pixel.g), 180)
    XCTAssertGreaterThan(Int(pixel.b), 180)
  }

  func testStopIsIdempotent() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: FakeHostTime()),
      hostTime: FakeHostTime())
    try await session.load()
    await session.stop()
    await session.stop()
  }

  /// Waits until playing really starts.
  ///
  /// The cache is empty when first built, and play reports buffering first —
  /// rightly, not a defect. What to pin is that it gets to playing by itself,
  /// not that it is playing at once.
  private func waitUntilPlaying(
    _ session: PlaybackSession, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    for _ in 0..<200 {
      if await session.phase == .playing { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("not playing within two seconds", file: file, line: line)
  }

  func testPhaseIsIdleBeforeLoading() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: FakeHostTime()),
      hostTime: FakeHostTime())
    let phase = await session.phase
    XCTAssertEqual(phase, .idle)
  }

  func testPhaseFollowsRate() async throws {
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }

    let loaded = await session.phase
    XCTAssertEqual(loaded, .paused, "loaded but not played is paused")

    try await session.play()
    try await waitUntilPlaying(session)

    await session.pause()
    let paused = await session.phase
    XCTAssertEqual(paused, .paused)
  }

  /// Playing to the end is told apart from stopping on an error.
  ///
  /// The feed loop was once `catch { break }`, and the two looked the same
  /// — a read failure nine minutes in looked like playing to the end.
  func testPhaseBecomesEndedAfterContentRunsOut() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    // The fixture is 2 seconds: play it out.
    try await playOut(session, host: host, output: output)
    let phase = await session.phase
    XCTAssertEqual(phase, .ended)
  }

  /// Moves time on until the session is over or `seconds` have passed.
  private func playOut(
    _ session: PlaybackSession, host: FakeHostTime, output: VirtualAudioOutput,
    seconds: Double = 5
  ) async throws {
    for _ in 0..<Int(seconds / 0.1) {
      if await session.phase.isTerminal { return }
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  func testPhaseIsIdleAfterStop() async throws {
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    try await session.play()
    await session.stop()
    let phase = await session.phase
    XCTAssertEqual(phase, .idle, "stopped, the session has let go of everything and is back where it began")
  }

  /// A seek while playing plays on, rather than stopping until the caller
  /// asks for play() again.
  ///
  /// The backlog limit is small: backpressure keeps feeding where it is, so
  /// it cannot run ahead to the end of the file and make the phase ended,
  /// and the check is certain.
  func testSeekWhilePlayingKeepsPlaying() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.5)
    let source = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    try await session.seek(to: CMTime(seconds: 2.0, preferredTimescale: 600))

    // After the seek the cache is empty: buffering first, then back to
    // playing. What to pin is that it **does** go back by itself, rather
    // than stopping as if paused.
    try await waitUntilPlaying(session)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 2.0, accuracy: 0.05, "the clock jumps to the target")
  }

  /// A seek while paused stays paused, with the clock at the target.
  func testSeekWhilePausedStaysPaused() async throws {
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }

    try await session.seek(to: CMTime(seconds: 2.0, preferredTimescale: 600))

    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 2.0, accuracy: 0.05)
  }

  func testSeekClampsBeyondDuration() async throws {
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }

    let duration = await session.duration
    try await session.seek(to: CMTime(seconds: 999, preferredTimescale: 600))
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, duration.seconds, accuracy: 0.05, "past the end, clamped to the duration")
  }

  func testSeekClampsNegative() async throws {
    let host = FakeHostTime()
    let source = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }

    try await session.seek(to: CMTime(seconds: -5, preferredTimescale: 600))
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 0, accuracy: 0.001, "negative, clamped to zero")
  }

  /// A seek back into the content after the end: "ended" no longer holds.
  func testSeekClearsEndedPhase() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await playOut(session, host: host, output: output)
    let ended = await session.phase
    XCTAssertEqual(ended, .ended, "precondition: played to the end first")

    try await session.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
    let phase = await session.phase
    XCTAssertNotEqual(phase, .ended, "no longer ended after seeking back into the content")
  }
}
