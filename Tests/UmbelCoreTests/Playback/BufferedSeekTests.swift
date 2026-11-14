import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class StillHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// An output that takes a few frames and then holds the feeder, as a real
/// one does while it plays them, and records what came since the last
/// flush. A flush can be held, to look at a seek half done.
private actor HoldingAudioOutput: AudioOutput {
  private let capacity: Int
  private var frames: [AudioFrame] = []
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private var flushesBeforeHold: Int?
  private var heldFlush: CheckedContinuation<Void, Never>?

  init(capacity: Int = 8) { self.capacity = capacity }

  var currentAnchor: RenderAnchor? { nil }
  func prepare(sampleRate: Double, channelCount: Int) async throws {}
  func start() async throws {}
  func pause() async {}
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Float, muted: Bool) {}

  func enqueue(_ frame: AudioFrame) async throws {
    while frames.count >= capacity { await withCheckedContinuation { waiting.append($0) } }
    frames.append(frame)
  }

  func flush() async {
    if flushesBeforeHold == 0 {
      flushesBeforeHold = nil
      await withCheckedContinuation { heldFlush = $0 }
    } else if let remaining = flushesBeforeHold {
      flushesBeforeHold = remaining - 1
    }
    clear()
  }

  func stop() async { clear() }

  var firstFrameTime: CMTime? { frames.first?.presentationTime }

  func holdNextFlush(after count: Int = 0) { flushesBeforeHold = count }
  var isHoldingFlush: Bool { heldFlush != nil }
  func releaseFlush() {
    heldFlush?.resume()
    heldFlush = nil
  }

  private func clear() {
    frames.removeAll()
    let woken = waiting
    waiting.removeAll()
    for producer in woken { producer.resume() }
  }
}

/// A seek forward into what is read already keeps it: reading goes on where
/// it is, the content after the target plays, and nothing is read again.
final class BufferedSeekTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

  private struct Playing {
    let session: PlaybackSession
    let output: HoldingAudioOutput
    let renderer: OffscreenVideoRenderer
    let diagnostics: UmbelPlaybackDiagnostics
  }

  /// seek_grid.mp4 playing with the clock held at the start, once its ten
  /// seconds of cache are read: white for the first tenth of every second,
  /// black the rest, a keyframe every two seconds.
  private func playing(
    _ name: String = "seek_grid.mp4", compositesSubtitles: Bool = true,
    buffering: BufferingConfiguration = .init()
  ) async throws -> Playing {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let output = HoldingAudioOutput()
    let diagnostics = UmbelPlaybackDiagnostics()
    let source: any UmbelSource = name.hasSuffix(".m3u8")
      ? FixtureServer().source(fixture(name)) : try UmbelFileSource(url: fixture(name))
    let session = PlaybackSession(
      source: source, audioOutput: output, videoRenderer: renderer,
      compositesSubtitles: compositesSubtitles, hostTime: StillHostTime(), buffering: buffering, diagnostics: diagnostics)
    try await session.load()
    addTeardownBlock { await session.stop() }
    return Playing(session: session, output: output, renderer: renderer, diagnostics: diagnostics)
  }

  private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
    for _ in 0..<250 {
      if try await condition() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting until \(what)")
  }

  private func waitForCache(_ session: PlaybackSession) async throws {
    try await waitUntil("ten seconds are read") { await session.bufferedDuration.seconds >= 9.9 }
  }

  /// What the seek did since `sequence`: the path it took, and whether the
  /// demuxer was moved.
  private func seekEvents(
    _ diagnostics: UmbelPlaybackDiagnostics, after sequence: UInt64
  ) -> (paths: [String], demuxSeeks: Int) {
    let events = diagnostics.snapshot(after: sequence).events
    return (events.filter { $0.name == "session_seek_path" }.compactMap { $0.labels["path"] },
            events.filter { $0.name == "demux_seek" }.count)
  }

  private func presentedTime(_ session: PlaybackSession) async throws -> Double {
    for _ in 0..<250 {
      if let frame = try await session.renderVideoFrame() { return frame.presentationTime.seconds }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("no picture after the seek")
    return -1
  }

  func testAForwardSeekIntoTheCacheKeepsItAndReadsNothingAgain() async throws {
    let playing = try await playing()
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    let mark = playing.diagnostics.snapshot().latestSequence

    try await session.seek(to: at(5.5))

    let seek = seekEvents(playing.diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["cache"])
    XCTAssertEqual(seek.demuxSeeks, 0, "the demuxer reads on where it was")
    let buffered = await session.bufferedDuration.seconds
    XCTAssertGreaterThan(buffered, 3.5, "what lies past the target is still there")

    let shown = try await presentedTime(session)
    XCTAssertGreaterThanOrEqual(shown, 5.5 - 0.001, "the picture starts at the target, not the keyframe")
    let pixel = try await playing.renderer.readAveragePixel(inRegion: .whole)
    XCTAssertLessThan(Int(pixel.r), 100, "dark at 5.5 s; the keyframe at 4 s is white")
    try await waitUntil("sound is queued") { await playing.output.firstFrameTime != nil }
    let first = await playing.output.firstFrameTime
    let sound = try XCTUnwrap(first)
    XCTAssertGreaterThanOrEqual(sound.seconds, 5.5 - 0.001, "nor does the sound start before it")
    try await waitUntil("it plays again") { await session.phase == .playing }
    let time = await session.currentTime.seconds
    XCTAssertEqual(time, 5.5, accuracy: 0.05)
    try await waitUntil("reading goes on up to the target again") {
      await session.bufferedDuration.seconds >= 9.9
    }
  }

  func testTwoSeeksForwardInARowBothKeepTheCache() async throws {
    let playing = try await playing()
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    let mark = playing.diagnostics.snapshot().latestSequence

    try await session.seek(to: at(3.5))
    try await session.seek(to: at(6.5))

    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).paths, ["cache", "cache"])
    let shown = try await presentedTime(session)
    XCTAssertGreaterThanOrEqual(shown, 6.5 - 0.001)
    XCTAssertLessThan(shown, 6.6)
  }

  func testASeekPastWhatIsReadReadsFromTheTarget() async throws {
    let playing = try await playing()
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    let mark = playing.diagnostics.snapshot().latestSequence

    try await session.seek(to: at(20.5))

    let seek = seekEvents(playing.diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["reread"])
    XCTAssertGreaterThan(seek.demuxSeeks, 0)
    let shown = try await presentedTime(session)
    XCTAssertGreaterThanOrEqual(shown, 20.5 - 0.001)
  }

  func testASeekBackReadsAgain() async throws {
    let playing = try await playing()
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    try await session.seek(to: at(5.5))
    let mark = playing.diagnostics.snapshot().latestSequence

    try await session.seek(to: at(2.5))

    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).paths, ["reread"])
    let shown = try await presentedTime(session)
    XCTAssertGreaterThanOrEqual(shown, 2.5 - 0.001)
    XCTAssertLessThan(shown, 2.6)
  }

  func testEnabledHistoryReplaysBackwardAndThenForwardWithoutDemuxSeeks() async throws {
    let playing = try await playing(buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    try await session.seek(to: at(5.5))
    let mark = playing.diagnostics.snapshot().latestSequence

    for target in [2.5, 6.5, 3.5] {
      try await session.seek(to: at(target))
      let shown = try await presentedTime(session)
      XCTAssertGreaterThanOrEqual(shown, target - 0.001)
      XCTAssertLessThan(shown, target + 0.1)
      try await waitUntil("sound is queued") { await playing.output.firstFrameTime != nil }
      let sound = await playing.output.firstFrameTime
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(sound).seconds, target - 0.001)
    }
    let events = seekEvents(playing.diagnostics, after: mark)
    XCTAssertEqual(events.paths, ["cache", "cache", "cache"])
    XCTAssertEqual(events.demuxSeeks, 0)
  }

  func testInsufficientHistoryBudgetUsesNormalSeek() async throws {
    let playing = try await playing(buffering: .init(maximumBackwardPacketBytes: 1))
    try await playing.session.play()
    try await waitForCache(playing.session)
    try await playing.session.seek(to: at(5.5))
    let mark = playing.diagnostics.snapshot().latestSequence
    try await playing.session.seek(to: at(2.5))
    let events = seekEvents(playing.diagnostics, after: mark)
    XCTAssertEqual(events.paths, ["reread"])
    XCTAssertGreaterThan(events.demuxSeeks, 0)
    let shown = try await presentedTime(playing.session)
    XCTAssertGreaterThanOrEqual(shown, 2.5 - 0.001)
  }

  func testBackwardReplayRestoresASubtitleThatWasPrunedFromDecodedTimeline() async throws {
    let playing = try await playing("multi_track.mkv", compositesSubtitles: false,
                                    buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    let session = playing.session
    let tracks = await session.tracks
    let subtitle = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await session.selectSubtitleTrack(subtitle.id)
    try await session.play()
    try await waitUntil("the file is buffered") { await session.bufferedDuration.seconds > 2.5 }
    try await session.seek(to: at(2.5))
    _ = try await presentedTime(session)
    let empty = await session.currentSubtitleCues
    XCTAssertTrue(empty.isEmpty, "querying at 2.5 prunes the first line, which ended at 1")
    let mark = playing.diagnostics.snapshot().latestSequence

    try await session.seek(to: at(0.5))
    _ = try await presentedTime(session)
    try await waitUntil("the earlier line is decoded again") {
      await session.currentSubtitleCues.flatMap(\.runs).map(\.text).joined() == "first line"
    }
    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).paths, ["cache"])
    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
  }

  func testPlaylistHistoryReplaysAcrossSegments() async throws {
    let playing = try await playing("hls/fmp4/index.m3u8",
                                    buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    try await playing.session.play()
    try await waitForCache(playing.session)
    try await playing.session.seek(to: at(6.5))
    _ = try await presentedTime(playing.session)
    let mark = playing.diagnostics.snapshot().latestSequence
    try await playing.session.seek(to: at(2.5))
    let shown = try await presentedTime(playing.session)
    XCTAssertGreaterThanOrEqual(shown, 2.5 - 0.001)
    XCTAssertLessThan(shown, 2.6)
    let decisions = playing.diagnostics.snapshot(after: mark).events.filter { $0.name == "session_seek_path" }
    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).paths, ["cache"], "\(decisions)")
    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
  }

  func testSwitchingAudioAfterCachedRewindReadsMissingSoundAgain() async throws {
    let playing = try await playing("multi_track.mkv",
                                    buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    let session = playing.session
    let tracks = await session.tracks
    let alternate = try XCTUnwrap(tracks.filter { $0.kind == .audio }.last)
    try await session.selectSubtitleTrack(nil)
    try await session.play()
    try await waitUntil("the file is buffered") { await session.bufferedDuration.seconds > 2.5 }
    try await session.seek(to: at(2.5))
    _ = try await presentedTime(session)
    try await session.seek(to: at(0.5))
    _ = try await presentedTime(session)
    let rewind = playing.diagnostics.snapshot().events.last { $0.name == "session_seek_path" }
    XCTAssertEqual(rewind?.labels["cache"], "backward")
    let mark = playing.diagnostics.snapshot().latestSequence
    try await session.selectAudioTrack(alternate.id)
    try await waitUntil("alternate sound is queued") { await playing.output.firstFrameTime != nil }
    let sound = await playing.output.firstFrameTime
    XCTAssertEqual(try XCTUnwrap(sound).seconds, 0.5, accuracy: 0.05)
    XCTAssertGreaterThan(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
  }

  private func rewindPastInactiveSubtitles(alternateAudio: Bool = false) async throws -> Playing {
    let playing = try await playing("backward_tracks.mkv", compositesSubtitles: false,
                                    buffering: .init(target: 30, maximumBackwardPacketBytes: 4 * 1024 * 1024))
    try await playing.session.selectSubtitleTrack(nil)
    if alternateAudio {
      let tracks = await playing.session.tracks
      try await playing.session.selectAudioTrack(try XCTUnwrap(tracks.filter { $0.kind == .audio }.last).id)
    }
    try await playing.session.play()
    try await waitUntil("the long file is buffered") { await playing.session.bufferedDuration.seconds > 23 }
    try await playing.session.seek(to: at(20.5))
    _ = try await presentedTime(playing.session)
    try await playing.session.seek(to: at(0.5))
    _ = try await presentedTime(playing.session)
    let rewind = playing.diagnostics.snapshot().events.last { $0.name == "session_seek_path" }
    XCTAssertEqual(rewind?.labels["cache"], "backward", "subtitles off must allow this cached rewind")
    return playing
  }

  func testEnablingEitherSubtitleSlotAfterRewindRecoversEvictedCue() async throws {
    for slot in UmbelSubtitleSlot.allCases {
      let playing = try await rewindPastInactiveSubtitles()
      let tracks = await playing.session.tracks
      let subtitle = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
      let mark = playing.diagnostics.snapshot().latestSequence
      try await playing.session.selectSubtitleTrack(subtitle.id, for: slot)
      try await waitUntil("the evicted cue is read again") {
        await playing.session.currentSubtitleCues(for: slot).map(\.plainText) == ["first line"]
      }
      XCTAssertGreaterThan(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
    }
  }

  func testAutomaticSubtitleSelectionAfterRewindRecoversEvictedCue() async throws {
    let playing = try await rewindPastInactiveSubtitles(alternateAudio: true)
    let mark = playing.diagnostics.snapshot().latestSequence
    try await playing.session.selectSubtitleTrackAutomatically()
    try await waitUntil("the forced cue is read again") {
      await playing.session.currentSubtitleCues.map(\.plainText) == ["第一行"]
    }
    XCTAssertGreaterThan(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
  }

  func testSubtitleDelayChangedWhileCachedSeekFinishesInvalidatesItsSnapshot() async throws {
    let playing = try await playing("multi_track.mkv", compositesSubtitles: false,
                                    buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    let tracks = await playing.session.tracks
    let subtitle = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await playing.session.selectSubtitleTrack(subtitle.id)
    try await playing.session.play()
    try await waitUntil("the file is buffered") { await playing.session.bufferedDuration.seconds > 2.5 }
    try await playing.session.seek(to: at(2.5))
    _ = try await presentedTime(playing.session)
    await playing.output.holdNextFlush(after: 1)
    let mark = playing.diagnostics.snapshot().latestSequence
    let target = at(1.5)
    let seek = Task { try await playing.session.seek(to: target) }
    try await waitUntil("the seek has made its cache decision") { await playing.output.isHoldingFlush }
    await playing.session.setSubtitleDelay(1)
    await playing.output.releaseFlush()
    try await seek.value
    try await waitUntil("the subtitle uses the revised delay") {
      await playing.session.currentSubtitleCues.map(\.plainText) == ["first line"]
    }
    XCTAssertGreaterThan(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0,
                         "the accepted snapshot became stale before restarting the feeders")
  }

  func testChangingOneLayerDoesNotRereadAnUnchangedBitmapLayer() async throws {
    let playing = try await playing("pgs_subs.mkv", compositesSubtitles: false)
    let tracks = await playing.session.tracks
    let bitmap = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await playing.session.selectSubtitleTrack(bitmap.id)
    try await playing.session.selectSubtitleTrack(bitmap.id, for: .secondary)
    try await playing.session.seek(to: at(3))
    _ = try await presentedTime(playing.session)
    let packetCache = await playing.session.cache
    let cache = try XCTUnwrap(packetCache)
    // Evict the compressed setup after it reached the live decoder. The
    // selected bitmap layer remains decoded; only rebuilding it needs reread.
    _ = await cache.take(from: bitmap.id, upTo: at(20))
    let requirements = await playing.session.subtitles.replayRequirements(at: at(3))
    let complete = await cache.canReplaySubtitles(requirements)
    XCTAssertFalse(complete, "precondition: rebuilding the bitmap layer would need old packets")
    let external = try await playing.session.addExternalSubtitle(
      UmbelFileSource(url: fixture("external_gbk.srt")))
    let mark = playing.diagnostics.snapshot().latestSequence
    try await playing.session.selectSubtitleTrack(nil, for: .secondary)
    try await playing.session.selectSubtitleTrack(external.id, for: .secondary)
    await playing.session.setSubtitleDelay(0.25, for: .secondary)
    try await playing.session.selectSubtitleTrack(nil, for: .secondary)
    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
  }

  func testPlaylistWithTimelineGapsFallsBackToNormalSeek() async throws {
    let playing = try await playing("hls/tagged.m3u8",
                                    buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    try await playing.session.play()
    try await waitForCache(playing.session)
    try await playing.session.seek(to: at(6.5))
    _ = try await presentedTime(playing.session)
    let mark = playing.diagnostics.snapshot().latestSequence
    try await playing.session.seek(to: at(2.5))
    let shown = try await presentedTime(playing.session)
    XCTAssertGreaterThanOrEqual(shown, 2.5 - 0.001)
    XCTAssertLessThan(shown, 2.6)
    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).paths, ["reread"])
    XCTAssertGreaterThan(seekEvents(playing.diagnostics, after: mark).demuxSeeks, 0)
  }

  func testCachedBackwardSeekPreservesPauseAndReportsPayloadBudget() async throws {
    let playing = try await playing(buffering: .init(maximumBackwardPacketBytes: 4 * 1024 * 1024))
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    try await session.seek(to: at(5.5))
    await session.pause()
    let mark = playing.diagnostics.snapshot().latestSequence
    try await session.seek(to: at(2.5))
    _ = try await presentedTime(session)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
    let position = await session.currentTime.seconds
    XCTAssertEqual(position, 2.5, accuracy: 0.001)
    let backward = await session.backwardPacketBytes
    XCTAssertGreaterThan(backward, 0)
    XCTAssertLessThanOrEqual(backward, 4 * 1024 * 1024)
    let decision = playing.diagnostics.snapshot(after: mark).events.first { $0.name == "session_seek_path" }
    XCTAssertEqual(decision?.labels["cache"], "backward")
    XCTAssertNotNil(decision?.values["backwardPacketBytes"])
  }

  /// A line taken before the seek stays: it is not read again, so clearing
  /// the subtitle decoders would lose it until the next line.
  func testASubtitleLineAlreadyShowingStaysAcrossASeekIntoTheCache() async throws {
    let playing = try await playing("long_movtext.mp4", compositesSubtitles: false)
    let session = playing.session
    let tracks = await session.tracks
    let line = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await session.selectSubtitleTrack(line.id)
    try await session.play()
    try await session.seek(to: at(1.5))
    try await waitUntil("the line shows") { await !session.currentSubtitleCues.isEmpty }
    try await waitUntil("the cache is read on past the next seek") {
      await session.bufferedDuration.seconds >= 9
    }
    let mark = playing.diagnostics.snapshot().latestSequence

    try await session.seek(to: at(6))

    XCTAssertEqual(seekEvents(playing.diagnostics, after: mark).paths, ["cache"])
    try await waitUntil("it plays again") { await session.phase == .playing }
    let cues = await session.currentSubtitleCues
    XCTAssertEqual(cues.flatMap(\.runs).map(\.text).joined(), "a long line")
  }

  /// While a seek is under way the position is its target, not where
  /// playback stood: a host showing it would otherwise jump back meanwhile.
  func testThePositionIsTheTargetWhileASeekIsUnderWay() async throws {
    let playing = try await playing()
    let session = playing.session
    try await session.play()
    try await waitForCache(session)
    await playing.output.holdNextFlush()

    let target = at(7.5)
    let seek = Task { try await session.seek(to: target) }
    try await waitUntil("the seek is under way") { await playing.output.isHoldingFlush }
    let during = await session.currentTime.seconds
    XCTAssertEqual(during, 7.5, accuracy: 0.001)

    await playing.output.releaseFlush()
    try await seek.value
    let after = await session.currentTime.seconds
    XCTAssertEqual(after, 7.5, accuracy: 0.05)
  }
}
