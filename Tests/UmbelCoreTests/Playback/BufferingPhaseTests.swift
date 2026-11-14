import CoreMedia
import XCTest
@testable import UmbelCore

private final class ManualHostTime: HostTimeSource, @unchecked Sendable {
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

/// A file source whose reads can be held back or failed over a byte range.
///
/// Real networks cannot reproduce "the read stalls halfway through" on demand;
/// a range the test controls can, and exactly. A range rather than a cut-off
/// offset, because the fixtures keep their index at the end of the file and
/// opening has to reach it.
private actor ScriptedSource: UmbelRandomAccessSource {
  private let inner: UmbelFileSource
  private var blocked: Range<Int64>?
  private var failing: Range<Int64>?

  init(fixture name: String) throws {
    inner = try UmbelFileSource(url: fixtureURL(name))
  }

  func block(_ range: Range<Int64>?) { blocked = range }
  func fail(_ range: Range<Int64>?) { failing = range }

  var contentLength: Int64? { get async { await inner.contentLength } }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    if let failing, failing.contains(offset) {
      throw UmbelError.sourceUnavailable(detail: "scripted failure at \(offset)")
    }
    while let blocked, blocked.contains(offset) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    // A read that starts before the range must not run into it either.
    var length = maxLength
    for range in [blocked, failing].compactMap({ $0 }) where offset < range.lowerBound {
      length = min(length, Int(range.lowerBound - offset))
    }
    return try await inner.read(offset: offset, maxLength: length)
  }

  func invalidate() async { await inner.invalidate() }
}

private func fixtureURL(_ name: String) -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
    .appendingPathComponent(name)
}

/// Where seek_grid.mp4's index begins; its media data comes before it.
///
/// Found at run time rather than written down: the fixture is encoded in
/// hardware, so regenerating it moves every byte.
private let seekGridIndexOffset: Int64 = topLevelBoxOffset("moov", in: "seek_grid.mp4")

private func topLevelBoxOffset(_ type: String, in fixture: String) -> Int64 {
  guard let data = try? Data(contentsOf: fixtureURL(fixture)) else { return 0 }
  var offset = 0
  while offset + 8 <= data.count {
    let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
    let name = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
    if name == type { return Int64(offset) }
    guard size >= 8 else { return 0 }
    offset += size
  }
  return 0
}

/// Reads small enough for a blocked range to bite where the test puts it; the
/// default 64 KB would pull in most of the fixture on the first read.
private let smallReads = DemuxConfiguration(ioBufferSize: 2_048)

final class BufferingPhaseTests: XCTestCase {
  private func waitForPhase(
    _ expected: UmbelPlaybackPhase,
    of session: PlaybackSession,
    within seconds: Double = 2,
    whileWaiting step: () async -> Void = {},
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await session.phase == expected { return }
      await step()
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let actual = await session.phase
    XCTFail("waited for \(expected), still \(actual)", file: file, line: line)
  }

  func testByteBudgetStartsAndResumesBelowTheTimeThresholds() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.2)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads,
      buffering: .init(startThreshold: 60, resumeThreshold: 80, target: 100, maximumPacketBytes: 1_024))
    addTeardownBlock { await session.stop() }
    try await session.load()
    await source.block(20_000..<seekGridIndexOffset)
    try await session.play()
    try await waitForPhase(.playing, of: session)
    let initialDuration = await session.bufferedDuration.seconds
    XCTAssertLessThan(initialDuration, 60)
    let bytes = await session.bufferedPacketBytes
    XCTAssertGreaterThan(bytes, 0)

    try await waitForPhase(.buffering, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
    await source.block(nil)
    try await waitForPhase(.playing, of: session)
    let resumedDuration = await session.bufferedDuration.seconds
    XCTAssertLessThan(resumedDuration, 80)
  }

  func testPacketsLargerThanTheBudgetStillPlayToTheEnd() async throws {
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.2)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixtureURL("audio_only.m4a")),
      audioOutput: output, hostTime: host,
      buffering: .init(startThreshold: 60, resumeThreshold: 80, target: 100, maximumPacketBytes: 1))
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    try await waitForPhase(.playing, of: session)
    try await waitForPhase(.ended, of: session, within: 10) {
      host.advance(seconds: 0.05)
      await output.advance(bySeconds: 0.05)
      await session.refreshClock()
    }
    let bytes = await session.bufferedPacketBytes
    XCTAssertEqual(bytes, 0)
  }

  func testReportsOpeningWhileLoading() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    await source.block(0..<Int64.max)
    let host = ManualHostTime()
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host),
      hostTime: host, configuration: smallReads)
    addTeardownBlock { await session.stop() }

    let loading = Task { try await session.load() }
    try await waitForPhase(.opening, of: session)

    await source.block(nil)
    try await loading.value
    let loaded = await session.phase
    XCTAssertEqual(loaded, .paused)
  }

  /// Asking to play is not the same as playing: until the start threshold is
  /// reached the session waits, and the clock waits with it.
  func testWaitsForTheStartThresholdBeforeTheClockMoves() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads)
    addTeardownBlock { await session.stop() }
    try await session.load()
    // Well under the two seconds needed to start.
    await source.block(3_000..<seekGridIndexOffset)

    try await session.play()
    try await Task.sleep(nanoseconds: 200_000_000)
    let waiting = await session.phase
    XCTAssertEqual(waiting, .buffering)

    host.advance(seconds: 3)
    await output.advance(bySeconds: 3)
    await session.refreshClock()
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 0, accuracy: 0.01, "the clock must not run while waiting")

    await source.block(nil)
    try await waitForPhase(.playing, of: session)
  }

  /// Running dry mid-play stops the clock, and refilling starts it again.
  ///
  /// Reporting buffering while the clock kept going was the first design; it
  /// lets video frames fall behind a clock with no sound under it, and the
  /// position leaps when the sound returns.
  func testRunningDryStopsTheClockUntilRefilled() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads,
      buffering: BufferingConfiguration(startThreshold: 2, lowWatermark: 1, target: 3))
    addTeardownBlock { await session.stop() }
    try await session.load()
    // Roughly the first seven seconds are readable.
    await source.block(20_000..<seekGridIndexOffset)

    try await session.play()
    try await waitForPhase(.playing, of: session)

    try await waitForPhase(.buffering, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }

    let stalledAt = await session.currentTime
    host.advance(seconds: 3)
    await output.advance(bySeconds: 3)
    await session.refreshClock()
    let later = await session.currentTime
    XCTAssertEqual(
      later.seconds, stalledAt.seconds, accuracy: 0.01,
      "a stalled clock must hold its position")

    await source.block(nil)
    try await waitForPhase(.playing, of: session)
  }

  /// A read that fails for good does not stop playback at once: what is
  /// already buffered plays out, and the failure is reported when it runs
  /// out. Reporting it straight away left the phase saying failed while
  /// sound and picture carried on for seconds.
  ///
  /// Bytes from 20 000 on fail: about the first seven seconds are readable.
  func testFailingReadPlaysOutTheBufferThenReportsWhy() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads)
    addTeardownBlock { await session.stop() }
    try await session.load()
    await source.fail(20_000..<seekGridIndexOffset)

    try await session.play()
    try await waitForPhase(.failed, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
    let reachedBeforeFailing = await session.currentTime.seconds
    XCTAssertGreaterThan(reachedBeforeFailing, 5, "the readable part played first")
    let reason = await session.failureReason
    guard case .sourceUnavailable = reason else {
      return XCTFail("expected a source failure, got \(String(describing: reason))")
    }
  }

  /// The read fails while playback is already waiting for data. Nothing
  /// else wakes the waiting then: the output is paused and feeding is held
  /// by it. Ending the input has to reopen the gate itself, or playback
  /// waits forever instead of playing out and reporting — which is what
  /// stopping a server mid-play did.
  ///
  /// The output holds a fifth of a second, as the real one does. Holding a
  /// whole second, it swallows the few packets left in the cache, and feeding
  /// then polls an empty cache — which happens to wake the gate and hides the
  /// deadlock.
  func testFailureWhileBufferingStillPlaysOutAndReports() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.2)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads,
      buffering: BufferingConfiguration(startThreshold: 2, lowWatermark: 1, target: 3))
    addTeardownBlock { await session.stop() }
    try await session.load()
    await source.block(20_000..<seekGridIndexOffset)
    try await session.play()
    // Playing first: right after play() the phase is buffering anyway, which
    // is starting, not running dry.
    try await waitForPhase(.playing, of: session)
    try await waitForPhase(.buffering, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }

    // Now the source dies for good.
    await source.fail(20_000..<seekGridIndexOffset)
    await source.block(nil)
    try await waitForPhase(.failed, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
  }

  /// The same, reaching the end instead of failing: the last bytes arrive
  /// while playback waits, and it has to finish rather than wait forever.
  func testEndReachedWhileBufferingStillFinishes() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.2)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads,
      buffering: BufferingConfiguration(startThreshold: 2, lowWatermark: 1, target: 3))
    addTeardownBlock { await session.stop() }
    try await session.load()
    // The last second or so of media data, held back.
    await source.block(79_000..<seekGridIndexOffset)
    try await session.seek(to: CMTime(seconds: 26, preferredTimescale: 600))
    try await session.play()
    try await waitForPhase(.playing, of: session)
    try await waitForPhase(.buffering, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }

    await source.block(nil)
    try await waitForPhase(.ended, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
  }

  /// A seek after a failed read tries again; if the source has recovered,
  /// playback does too.
  func testSeekAfterAFailedReadTriesAgain() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host, configuration: smallReads)
    addTeardownBlock { await session.stop() }
    try await session.load()
    await source.fail(20_000..<seekGridIndexOffset)
    try await session.play()
    try await waitForPhase(.failed, of: session, within: 10) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }

    await source.fail(nil)
    try await session.seek(to: CMTime(seconds: 10, preferredTimescale: 600))
    try await waitForPhase(.playing, of: session)
    let reason = await session.failureReason
    XCTAssertNil(reason)
  }

  func testFailedLoadReportsFailedWithAReason() async throws {
    let source = try UmbelFileSource(url: fixtureURL("truncated.mp4"))
    let session = PlaybackSession(source: source)
    addTeardownBlock { await session.stop() }

    do {
      try await session.load()
      XCTFail("a truncated file must not load")
    } catch {}
    let phase = await session.phase
    XCTAssertEqual(phase, .failed)
    let reason = await session.failureReason
    XCTAssertNotNil(reason)
  }

  /// What is waiting ahead of the decoders: the whole two-second file, less
  /// what the output and the decoder took before backpressure held them.
  func testBufferedDurationMatchesTheCache() async throws {
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.5)
    let source = try UmbelFileSource(url: fixtureURL("audio_only.m4a"))
    let session = PlaybackSession(
      source: source, audioOutput: output, hostTime: host)
    addTeardownBlock { await session.stop() }
    try await session.load()
    let before = await session.bufferedDuration
    XCTAssertEqual(before.seconds, 0)

    try await session.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    let buffered = await session.bufferedDuration
    XCTAssertEqual(buffered.seconds, 1.45, accuracy: 0.15)
  }

  /// A seek is reported as a single stretch of buffering.
  ///
  /// It clears the cache, rebuilds decoder state and restarts both loops; a
  /// naive criterion flickers at each of those steps. The host draws its
  /// buffering indicator from this, and a flicker becomes a blinking icon — or
  /// worse, one left stuck on.
  func testSeekReportsBufferingExactlyOnce() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host),
      hostTime: host, configuration: smallReads)
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    try await waitForPhase(.playing, of: session)

    let sampler = Task { () -> [UmbelPlaybackPhase] in
      var seen: [UmbelPlaybackPhase] = []
      while !Task.isCancelled {
        let phase = await session.phase
        if phase != seen.last { seen.append(phase) }
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
      return seen
    }

    // Hold the refill back long enough that buffering cannot slip between
    // two samples unseen. Seeking an indexed file reads nothing itself; only
    // the refill waits on the block.
    await source.block(40_000..<seekGridIndexOffset)
    try await session.seek(to: CMTime(seconds: 20, preferredTimescale: 600))
    try await Task.sleep(nanoseconds: 300_000_000)

    // While it refills, the clock stays on the target instead of running on
    // ahead of content that has not arrived.
    host.advance(seconds: 2)
    let during = await session.currentTime
    XCTAssertEqual(during.seconds, 20, accuracy: 0.05)

    await source.block(nil)
    try await waitForPhase(.playing, of: session)
    try await Task.sleep(nanoseconds: 50_000_000)
    sampler.cancel()

    let seen = await sampler.value
    XCTAssertEqual(seen, [.playing, .buffering, .playing])
  }

  /// Audio before a seek target must not count toward starting.
  ///
  /// seek_grid has a key frame every two seconds, so a seek to 3.9 s reads
  /// from 2.0 s. Only bytes up to about 4.5 s are let through: 0.6 s past the
  /// target, short of the two seconds needed to start. Counted, the 1.9 s
  /// before the target would lift the level past the threshold — the session
  /// would report playing and run dry straight after, two buffering reports
  /// for one seek.
  ///
  /// Two seconds of cache, behind a second the output holds, stop reading
  /// short of the target: read past it, the seek would keep what is read
  /// instead of reading from the keyframe.
  func testAudioBeforeASeekTargetDoesNotCountTowardStarting() async throws {
    let source = try ScriptedSource(fixture: "seek_grid.mp4")
    let host = ManualHostTime()
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: host),
      hostTime: host, configuration: smallReads, buffering: .init(target: 2), diagnostics: diagnostics)
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    try await waitForPhase(.playing, of: session)

    let sampler = Task { () -> [UmbelPlaybackPhase] in
      var seen: [UmbelPlaybackPhase] = []
      while !Task.isCancelled {
        let phase = await session.phase
        if phase != seen.last { seen.append(phase) }
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
      return seen
    }
    // 13_137 is where the video packet at 4.5 s begins in this fixture.
    await source.block(13_137..<seekGridIndexOffset)
    try await session.seek(to: CMTime(seconds: 3.9, preferredTimescale: 600))
    try await Task.sleep(nanoseconds: 300_000_000)
    sampler.cancel()
    let paths = diagnostics.snapshot().events.filter { $0.name == "session_seek_path" }
    XCTAssertEqual(paths.compactMap { $0.labels["path"] }, ["reread"], "read again from the keyframe")
    let seen = await sampler.value
    XCTAssertEqual(seen, [.playing, .buffering], "nothing past the target is enough to start")

    await source.block(nil)
    try await waitForPhase(.playing, of: session)
  }

  func testErrorsDescribeThemselves() {
    let error: Error = UmbelError.trackUnavailable("no track 7")
    XCTAssertTrue(error.localizedDescription.contains("no track 7"))
  }
}
