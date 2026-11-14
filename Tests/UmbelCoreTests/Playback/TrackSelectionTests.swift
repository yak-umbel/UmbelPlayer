import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

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

private final class FixedHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// An output double that keeps the samples and applies backpressure.
///
/// The backpressure is needed: the fixture is 3 seconds, and unchecked,
/// feeding would read to the end in tens of milliseconds, leaving nothing
/// new to check after a switch. The protocol asks for "full means wait"
/// anyway.
private actor RecordingAudioOutput: AudioOutput {
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Float, muted: Bool) {}
  private var frames: [AudioFrame] = []
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let limit: Int
  private(set) var prepareCalls: [Int] = []

  init(limit: Int = 20) { self.limit = limit }

  var currentAnchor: RenderAnchor? { nil }
  var pendingCount: Int { frames.count }

  func prepare(sampleRate: Double, channelCount: Int) async throws {
    prepareCalls.append(channelCount)
  }

  func enqueue(_ frame: AudioFrame) async throws {
    while frames.count >= limit {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        waiters.append(continuation)
      }
    }
    frames.append(frame)
  }

  func start() async throws {}
  func pause() async {}
  func flush() async { frames.removeAll(); release() }
  func stop() async { frames.removeAll(); release() }

  /// Takes what was queued and lets the producer go.
  func take() -> [AudioFrame] {
    let taken = frames
    frames.removeAll()
    release()
    return taken
  }

  private func release() {
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

/// Estimates frequency from zero crossings. 440 and 880 are an octave apart;
/// a rough estimate tells them apart.
///
/// The frequency is checked rather than `selectedAudioTrack` changing: that
/// would show only that we remember our own setting, not that the sound
/// sent out really changed.
private func estimatedFrequency(_ frames: [AudioFrame]) -> Double {
  guard let rate = frames.first?.sampleRate, rate > 0 else { return 0 }
  var crossings = 0
  var counted = 0
  var previous: Float = 0
  for frame in frames {
    // Planar: channel 0's first frameCount samples only.
    for index in 0..<frame.frameCount {
      let value = frame.samples[index]
      if (previous < 0 && value >= 0) || (previous >= 0 && value < 0) { crossings += 1 }
      previous = value
      counted += 1
    }
  }
  guard counted > 0 else { return 0 }
  return Double(crossings) / 2 * (rate / Double(counted))
}

private final class SteppedHostTime: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func set(seconds value: Double) {
    lock.lock()
    defer { lock.unlock() }
    seconds = value
  }
}

final class TrackSelectionTests: XCTestCase {
  private func loadedSession() async throws -> PlaybackSession {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = PlaybackSession(
      source: source,
      audioOutput: VirtualAudioOutput(hostTime: FixedHostTime()),
      hostTime: FixedHostTime())
    try await session.load()
    return session
  }

  /// Opened, the track chosen is the one the container marks default, not
  /// whichever happens to come first.
  func testDefaultAudioTrackIsSelectedOnLoad() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }

    let tracks = await session.tracks
    let expected = try XCTUnwrap(
      tracks.first { $0.kind == .audio && $0.isDefault },
      "the fixture marks audio track 0 default")
    let selected = await session.selectedAudioTrack
    XCTAssertEqual(selected, expected.id)
  }

  /// Ordinary subtitles never switch themselves on. The fixture's Chinese
  /// track is forced, but the audio is English, so it stays off too.
  func testNoSubtitleIsSelectedOnLoad() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }

    let selected = await session.selectedSubtitleTrack
    XCTAssertNil(selected, "subtitles are off by default")
  }

  func testNothingIsSelectedBeforeLoad() async throws {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = PlaybackSession(
      source: source,
      audioOutput: VirtualAudioOutput(hostTime: FixedHostTime()),
      hostTime: FixedHostTime())
    let audio = await session.selectedAudioTrack
    XCTAssertNil(audio)
  }

  // ── The selection rule itself ────────────────────────
  //
  // In the fixture the default track happens to come first, so choosing by
  // default and choosing the first give the same result — tested on the
  // fixture alone, a rule of "take the first" would pass all the same. The
  // three below test the rule on made-up tracks, shapes the fixture does
  // not cover.

  private func track(_ index: Int32, _ kind: UmbelTrack.Kind, isDefault: Bool) -> UmbelTrack {
    UmbelTrack(
      id: UmbelTrack.ID(rawValue: index), kind: kind, codecName: "test",
      language: nil, title: nil, isDefault: isDefault, isForced: false,
      video: nil, audio: nil)
  }

  func testPrefersTheDefaultEvenWhenItIsNotFirst() {
    let tracks = [
      track(0, .audio, isDefault: false),
      track(1, .audio, isDefault: true),
    ]
    let picked = TrackPreference.preferred(of: .audio, in: tracks)
    XCTAssertEqual(picked?.id, UmbelTrack.ID(rawValue: 1), "the default flag comes before order")
  }

  func testFallsBackToTheFirstWhenNoneIsDefault() {
    let tracks = [
      track(3, .audio, isDefault: false),
      track(4, .audio, isDefault: false),
    ]
    let picked = TrackPreference.preferred(of: .audio, in: tracks)
    XCTAssertEqual(picked?.id, UmbelTrack.ID(rawValue: 3))
  }

  /// A container may mark several default. The rule has to take the
  /// earliest, or the same file opened twice could get different tracks —
  /// the hardest kind of uncertainty to trace.
  func testPicksTheEarliestAmongSeveralDefaults() {
    let tracks = [
      track(0, .video, isDefault: true),
      track(1, .audio, isDefault: true),
      track(2, .audio, isDefault: true),
    ]
    let picked = TrackPreference.preferred(of: .audio, in: tracks)
    XCTAssertEqual(picked?.id, UmbelTrack.ID(rawValue: 1), "chosen among its own kind only, the earliest")
  }

  func testReturnsNilWhenNoTrackOfThatKind() {
    let tracks = [track(0, .video, isDefault: true)]
    XCTAssertNil(TrackPreference.preferred(of: .audio, in: tracks))
  }

  // ── Switching ────────────────────────────────────────

  private func playingSession(
    output: RecordingAudioOutput,
    renderer: OffscreenVideoRenderer? = nil
  ) async throws -> PlaybackSession {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = PlaybackSession(
      source: source, audioOutput: output, videoRenderer: renderer,
      hostTime: FixedHostTime())
    try await session.load()
    try await session.play()
    return session
  }

  /// At the byte budget reading drops what no chain takes, the other sound
  /// track's packets among them. Switched to, that track is read again from
  /// where playback stands: its sound would otherwise go on from where
  /// reading had got to, ahead of the picture.
  func testASoundTrackDroppedAtTheByteBudgetIsReadAgainWhenSwitchedTo() async throws {
    let output = RecordingAudioOutput()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: Fixture.url("multi_track.mkv")), audioOutput: output,
      hostTime: FixedHostTime(), buffering: .init(target: 100, maximumPacketBytes: 8_192))
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    // Playback stands at the start; reading stops at the budget well ahead
    // of it, and what no chain takes is dropped.
    for _ in 0..<200 where await session.bufferedPacketBytes < 8_192 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let ahead = await session.bufferedDuration.seconds
    XCTAssertGreaterThanOrEqual(ahead, 0.5, "precondition: reading got well ahead of playback")
    let tracks = await session.tracks
    let other = try XCTUnwrap(tracks.first { $0.kind == .audio && $0.audio?.channelCount == 2 })

    try await session.selectAudioTrack(other.id)
    var first: AudioFrame?
    for _ in 0..<200 where first == nil {
      first = await output.take().first { $0.channelCount == 2 }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let start = try XCTUnwrap(first, "the track switched to plays").presentationTime.seconds
    XCTAssertLessThan(start, 0.3, "the sound switched to goes on from where playback stood")
  }

  /// Waits for the output to fill — full means feeding is held back by the
  /// backpressure, and enough has gathered to check.
  private func waitForAudio(_ output: RecordingAudioOutput) async throws {
    for _ in 0..<200 {
      if await output.pendingCount >= 10 { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("not enough audio within two seconds")
  }

  /// After a switch the sound sent out really changes: 440 to 880 Hz, one
  /// channel to two.
  func testSwitchingAudioTrackChangesTheSound() async throws {
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output)
    addTeardownBlock { await session.stop() }

    try await waitForAudio(output)
    let first = await output.take()
    XCTAssertEqual(estimatedFrequency(first), 440, accuracy: 60)
    XCTAssertEqual(first.first?.channelCount, 1)

    let tracks = await session.tracks
    let other = try XCTUnwrap(tracks.first { $0.kind == .audio && !$0.isDefault })
    try await session.selectAudioTrack(other.id)

    try await waitForAudio(output)
    let second = await output.take()
    XCTAssertEqual(estimatedFrequency(second), 880, accuracy: 60)
    // At the switch at most one frame of the old track is on its way:
    // feeding was waiting on backpressure then, holding a frame from the old
    // decoder, which lands in the new output once flush lets it go. 23 ms of
    // mono in a stereo output (one channel sounding, one silent), unheard.
    // **Pinned at one frame** — should it grow into a batch, this catches it.
    let stale = second.filter { $0.channelCount != 2 }.count
    XCTAssertLessThanOrEqual(stale, 1, "at most one frame of the old track on its way at a switch")
    XCTAssertEqual(second.last?.channelCount, 2, "everything after is in the format of the new track")

    let selected = await session.selectedAudioTrack
    XCTAssertEqual(selected, other.id)
  }

  /// The output is reconfigured for the new track's channel count.
  func testSwitchingReconfiguresTheOutput() async throws {
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output)
    addTeardownBlock { await session.stop() }
    try await waitForAudio(output)

    let tracks = await session.tracks
    let other = try XCTUnwrap(tracks.first { $0.kind == .audio && !$0.isDefault })
    try await session.selectAudioTrack(other.id)

    let calls = await output.prepareCalls
    XCTAssertEqual(calls.last, 2, "the last prepare used the channel count of the new track")
  }

  /// At the moment of switching the video queue is not flushed and no video
  /// frame is dropped.
  ///
  /// The direct evidence that switching audio does not restart the video
  /// chain. **After** it, the position jumps about 120 ms as queued audio is
  /// dropped, and video drops two or three frames to catch up — a separate
  /// matter.
  func testSwitchingAudioDoesNotFlushTheVideoQueue() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output, renderer: renderer)
    addTeardownBlock { await session.stop() }

    for _ in 0..<200 {
      if await renderer.queueDepth > 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let depthBefore = await renderer.queueDepth
    let droppedBefore = await renderer.totalDroppedFrames

    let tracks = await session.tracks
    let other = try XCTUnwrap(tracks.first { $0.kind == .audio && !$0.isDefault })
    try await session.selectAudioTrack(other.id)

    let depthAfter = await renderer.queueDepth
    let droppedAfter = await renderer.totalDroppedFrames
    // At least, not equal: feeding keeps adding frames while the switch runs,
    // so the queue may grow. Only a shrink would mean it was flushed.
    XCTAssertGreaterThanOrEqual(depthAfter, depthBefore, "switching the audio track does not flush the video queue")
    XCTAssertEqual(droppedAfter, droppedBefore, "switching the audio track drops no video frame")
  }

  func testSwitchingToAMissingTrackKeepsTheCurrentOne() async throws {
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output)
    addTeardownBlock { await session.stop() }
    let before = await session.selectedAudioTrack

    do {
      try await session.selectAudioTrack(UmbelTrack.ID(rawValue: 99))
      XCTFail("a track number that does not exist throws")
    } catch {
      // As expected
    }
    let after = await session.selectedAudioTrack
    XCTAssertEqual(after, before, "after a failure the old track stays")
  }

  /// Switching to the track already chosen does nothing — it must not clear
  /// the audio queued.
  func testSwitchingToTheSameTrackIsIdempotent() async throws {
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output)
    addTeardownBlock { await session.stop() }
    try await waitForAudio(output)

    let selectedNow = await session.selectedAudioTrack
    let current = try XCTUnwrap(selectedNow)
    let pendingBefore = await output.pendingCount
    try await session.selectAudioTrack(current)
    let pendingAfter = await output.pendingCount
    XCTAssertEqual(pendingAfter, pendingBefore, "an idempotent call does not clear the output")
  }

  /// With sound off, the clock's authority falls back to the host.
  func testSelectingNoAudioFallsBackToHostClock() async throws {
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output)
    addTeardownBlock { await session.stop() }

    try await session.selectAudioTrack(nil)
    let selected = await session.selectedAudioTrack
    XCTAssertNil(selected)
    let authority = await session.clockAuthority
    XCTAssertEqual(authority, .host)
  }

  // ── Subtitles ────────────────────────────────────────

  /// Keeps releasing backpressure until the session shows `expected`.
  /// Subtitles are sparse — one a second in the fixture — so a single release
  /// is not always enough to feed the next one through.
  private func waitForCues(
    _ expected: [String], in session: PlaybackSession, releasing output: RecordingAudioOutput,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    var seen: [String] = []
    for _ in 0..<100 {
      seen = await session.currentSubtitleCues.map(\.plainText)
      if seen == expected { return }
      _ = await output.take()
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("expected \(expected), still showing \(seen)", file: file, line: line)
  }

  /// The text on screen comes from the selected track, and only from it.
  ///
  /// Asserting the decoded words rather than which packets were routed: it
  /// proves the same routing and everything after it, with no hook into the
  /// session to do so.
  func testSubtitlesComeFromTheSelectedTrack() async throws {
    let output = RecordingAudioOutput()
    let host = SteppedHostTime()
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }

    let tracks = await session.tracks
    let subtitles = tracks.filter { $0.kind == .subtitle }
    XCTAssertEqual(subtitles.count, 2, "the fixture has two subtitle tracks")

    try await session.selectSubtitleTrack(subtitles[0].id)
    try await session.play()
    try await waitForCues(["first line"], in: session, releasing: output)

    // The Chinese track's first cue went past before the switch; its second,
    // at one second, has not.
    try await session.selectSubtitleTrack(subtitles[1].id)
    host.set(seconds: 1.5)
    try await waitForCues(["第二行"], in: session, releasing: output)
  }

  /// Turning subtitles off clears the screen at once.
  func testNoSubtitlesWhenDeselected() async throws {
    let output = RecordingAudioOutput()
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: FixedHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }

    let tracks = await session.tracks
    let subtitle = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await session.selectSubtitleTrack(subtitle.id)
    try await session.play()
    try await waitForCues(["first line"], in: session, releasing: output)

    try await session.selectSubtitleTrack(nil)
    let after = await session.currentSubtitleCues
    XCTAssertTrue(after.isEmpty, "no subtitles once turned off")
  }

  /// Choosing an audio track's number as subtitles is refused.
  func testSelectingAnAudioTrackAsSubtitleThrows() async throws {
    let output = RecordingAudioOutput()
    let session = try await playingSession(output: output)
    addTeardownBlock { await session.stop() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    do {
      try await session.selectSubtitleTrack(audio.id)
      XCTFail("the wrong kind throws")
    } catch {
      // As expected
    }
  }
}
