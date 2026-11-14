import CoreMedia
import XCTest
@testable import UmbelCore

final class PacketByteBudgetTests: XCTestCase {
  private let video = UmbelTrack.ID(rawValue: 0)
  private let audio = UmbelTrack.ID(rawValue: 1)
  private let subtitle = UmbelTrack.ID(rawValue: 2)

  private func packet(
    _ track: UmbelTrack.ID, bytes: Int, at seconds: Double = 0,
    duration: Double = 0.1, keyframe: Bool = true
  ) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: bytes),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: .invalid,
      duration: CMTime(seconds: duration, preferredTimescale: 600), isKeyframe: keyframe)
  }

  func testBytePressureCountsAllTracksAndReleasesBothBufferingThresholds() async {
    let cache = PacketCache(
      configuration: .init(startThreshold: 4, resumeThreshold: 8, target: 10, maximumPacketBytes: 100),
      measuredTrack: audio)
    await cache.append(packet(audio, bytes: 40))
    await cache.append(packet(video, bytes: 60))
    let full = await cache.isFull
    let bytes = await cache.bufferedPacketBytes
    let readiness = await cache.playbackReadiness
    XCTAssertEqual(bytes, 100)
    XCTAssertTrue(full)
    XCTAssertTrue(readiness.canStart)
    XCTAssertTrue(readiness.canResume)
    XCTAssertFalse(readiness.isStarving)
    _ = await cache.take(from: video, keeping: [audio, video])
    let draining = await cache.playbackReadiness
    XCTAssertFalse(draining.isStarving, "draining a byte-limited buffer must not immediately pause it")
    _ = await cache.take(from: audio, keeping: [audio, video])
    let empty = await cache.playbackReadiness
    XCTAssertTrue(empty.isStarving)
  }

  func testAnEmptyMeasuredQueueCannotResumeFromUnrelatedRemainingBytes() async throws {
    let cache = PacketCache(configuration: .init(maximumPacketBytes: 100), measuredTrack: audio)
    await cache.append(packet(audio, bytes: 40))
    await cache.append(packet(video, bytes: 60))
    let run = PlaybackRunState(
      clock: PresentationClock(hostTime: SystemHostTimeSource()), audioOutput: nil, cache: cache)
    try await run.setWantsToPlay(true)
    try await run.setOutputsReady(true)
    try await run.update()
    _ = await cache.take(from: audio, keeping: [audio, video])
    for _ in 0..<5 {
      try await run.update()
      let running = await run.isRunning
      XCTAssertFalse(running, "unrelated remaining bytes cannot reopen a starved measured queue")
    }
    await cache.append(packet(audio, bytes: 40))
    try await run.update()
    let refilled = await run.isRunning
    XCTAssertTrue(refilled)
  }

  func testNoByteBudgetPreservesTemporalBehavior() async {
    let cache = PacketCache(configuration: .init(target: 10), measuredTrack: audio)
    await cache.append(packet(audio, bytes: 1_000_000))
    let full = await cache.isFull
    let ready = await cache.hasEnoughToPlay
    XCTAssertFalse(full)
    XCTAssertFalse(ready)
  }

  func testNoMeasuredTrackStillStopsAtTheByteBudget() async {
    let cache = PacketCache(configuration: .init(maximumPacketBytes: 10), measuredTrack: nil)
    await cache.append(packet(video, bytes: 11))
    let full = await cache.isFull
    let ready = await cache.hasEnoughToPlay
    XCTAssertTrue(full)
    XCTAssertTrue(ready)
  }

  func testAnOversizedPacketCanBeConsumedAndFlushResetsBytePressure() async {
    let cache = PacketCache(configuration: .init(maximumPacketBytes: 10), measuredTrack: audio)
    await cache.append(packet(audio, bytes: 100))
    let full = await cache.isFull
    XCTAssertTrue(full)
    let taken = await cache.take(from: audio, keeping: [audio])
    XCTAssertEqual(taken?.data.count, 100)
    let drained = await cache.bufferedPacketBytes
    XCTAssertEqual(drained, 0)
    await cache.append(packet(audio, bytes: 100))
    await cache.flush()
    await cache.append(packet(audio, bytes: 1))
    let bytes = await cache.bufferedPacketBytes
    let readiness = await cache.playbackReadiness
    XCTAssertEqual(bytes, 1)
    XCTAssertFalse(readiness.canStart)
    XCTAssertTrue(readiness.isStarving)
  }

  func testDequeuePruneSubtitleDeliveryAndKeyframeSkipReleaseTheirBytes() async {
    let cache = PacketCache(
      configuration: .init(maximumPacketBytes: 200), measuredTrack: video,
      subtitleTracks: [subtitle], audioTracks: [audio])
    await cache.append(packet(audio, bytes: 20))
    await cache.append(packet(subtitle, bytes: 30))
    await cache.append(packet(video, bytes: 40, at: 1))
    await cache.append(packet(video, bytes: 50, at: 2, keyframe: false))
    await cache.append(packet(video, bytes: 60, at: 3))
    _ = await cache.take(from: subtitle, upTo: .zero)
    let afterSubtitle = await cache.bufferedPacketBytes
    XCTAssertEqual(afterSubtitle, 170)
    _ = await cache.take(from: video, keeping: [video])
    let afterPruning = await cache.bufferedPacketBytes
    XCTAssertEqual(afterPruning, 110)
    let remembered = await cache.routeSubtitles(to: subtitle)
    XCTAssertEqual(remembered.count, 1, "subtitle history is retained outside the forward budget")
    let cached = await cache.cachedAudioRanges(for: audio)
    XCTAssertFalse(cached.isEmpty, "retained audio is independent of the forward queue")
    let skipped = await cache.skipToKeyframe(of: video, atOrBefore: CMTime(seconds: 3, preferredTimescale: 600))
    XCTAssertEqual(skipped, 1)
    let afterSkip = await cache.bufferedPacketBytes
    XCTAssertEqual(afterSkip, 60)
  }

  func testOnDemandAudioDoesNotDisableTheByteBudget() async {
    let cache = PacketCache(configuration: .init(target: 1, maximumPacketBytes: 100), measuredTrack: video)
    await cache.setMeasuredTrack(video, takenOnDemand: audio)
    await cache.append(packet(video, bytes: 100, duration: 3))
    let full = await cache.isFull
    XCTAssertTrue(full, "selected picture packets must not grow without bound while sound is empty")
    _ = await cache.take(from: video, keeping: [video, audio])
    let canRead = await cache.prepareToRead()
    XCTAssertTrue(canRead)
  }

  func testInactiveTracksReleaseBytePressureWithoutDroppingSelectedPackets() async {
    let cache = PacketCache(configuration: .init(maximumPacketBytes: 100), measuredTrack: audio)
    await cache.append(packet(video, bytes: 90))
    await cache.append(packet(audio, bytes: 20))
    await cache.select([audio], revision: 0)
    let canRead = await cache.prepareToRead()
    let bytes = await cache.bufferedPacketBytes
    XCTAssertTrue(canRead)
    XCTAssertEqual(bytes, 20)
    let preserved = await cache.take(from: audio, keeping: [audio])
    XCTAssertEqual(preserved?.data.count, 20)
  }

  /// Routes published one after another can reach the cache out of order:
  /// the later one's selection stands.
  func testASelectionArrivingAfterALaterOneChangesNothing() async {
    let cache = PacketCache(configuration: .init(maximumPacketBytes: 10), measuredTrack: audio)
    await cache.select([video], revision: 2)
    await cache.select([audio], revision: 1)
    await cache.append(packet(video, bytes: 20))
    let canRead = await cache.prepareToRead()
    XCTAssertFalse(canRead, "the picture selected last is kept, so the cache stays full")
    let kept = await cache.take(from: video, keeping: [video])
    XCTAssertEqual(kept?.data.count, 20)
  }

  /// Sound no chain takes is dropped at the budget; switched to later, what
  /// it lacks past where playback stands is known, until the cache empties.
  func testWhatWasDroppedOfATrackIsKnownUntilTheCacheEmpties() async {
    let other = UmbelTrack.ID(rawValue: 3)
    let cache = PacketCache(configuration: .init(maximumPacketBytes: 100), measuredTrack: audio)
    await cache.select([audio], revision: 0)
    await cache.append(packet(other, bytes: 10, at: 4))
    await cache.append(packet(audio, bytes: 100, at: 0))
    _ = await cache.prepareToRead()
    let lacking = await cache.dropped(other, after: CMTime(seconds: 3, preferredTimescale: 600))
    let passed = await cache.dropped(other, after: CMTime(seconds: 4, preferredTimescale: 600))
    let kept = await cache.dropped(audio, after: .zero)
    XCTAssertTrue(lacking)
    XCTAssertFalse(passed, "playback has gone past all that was dropped")
    XCTAssertFalse(kept)
    await cache.flush()
    let flushed = await cache.dropped(other, after: CMTime(seconds: 3, preferredTimescale: 600))
    XCTAssertFalse(flushed)
  }

  /// Subtitles not shown are small, and one switched to must find the line
  /// on screen and those to come: at the budget they stay, and pass into
  /// the track's past as playback goes by them.
  func testSubtitlesNotShownStayAtTheByteBudget() async {
    let other = UmbelTrack.ID(rawValue: 3)
    let cache = PacketCache(
      configuration: .init(maximumPacketBytes: 100), measuredTrack: audio, subtitleTracks: [subtitle, other])
    await cache.select([audio, subtitle], revision: 0)
    await cache.append(packet(other, bytes: 5, at: 1))
    await cache.append(packet(audio, bytes: 50, at: 0))
    await cache.append(packet(audio, bytes: 50, at: 2))
    let canRead = await cache.prepareToRead()
    XCTAssertFalse(canRead, "precondition: at the budget")
    _ = await cache.take(from: audio, keeping: [audio, subtitle])
    _ = await cache.take(from: audio, keeping: [audio, subtitle])
    let past = await cache.routeSubtitles(to: other)
    XCTAssertEqual(past.count, 1, "the line not shown was kept, then passed into the track's past")
  }

  func testSubtitleOnlyPressureCannotHoldReadingAheadOfTheFirstMediaPacket() async {
    let cache = PacketCache(
      configuration: .init(maximumPacketBytes: 10), measuredTrack: audio, subtitleTracks: [subtitle])
    await cache.select([audio, subtitle], revision: 0)
    _ = await cache.routeSubtitles(to: subtitle)
    await cache.append(packet(subtitle, bytes: 100, at: 60))
    let canRead = await cache.prepareToRead()
    XCTAssertTrue(canRead, "a future subtitle cannot hold the demuxer before media arrives")
    let admitted = await cache.append(packet(audio, bytes: 20))
    XCTAssertTrue(admitted)
    let media = await cache.take(from: audio, keeping: [audio, subtitle])
    XCTAssertEqual(media?.data.count, 20)
  }

  func testReaderAdmitsOneOversizedPrerollPacketAtATime() async throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/b_frames.mkv")
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let target = CMTime(seconds: 1.9, preferredTimescale: 600)
    try await demux.seek(to: target)
    let cache = PacketCache(configuration: .init(target: 100, maximumPacketBytes: 1), measuredTrack: video.id)
    let reader = PacketReader(demux: demux, cache: cache)
    await reader.armPreroll(at: target, video: video.id, audio: nil)
    await reader.start(onRead: {}, onEnd: { _ in await cache.markEndOfContent() })
    for _ in 0..<200 {
      if await cache.bufferedPacketBytes > 0 { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    try await Task.sleep(nanoseconds: 80_000_000)
    await reader.cancel()
    await reader.waitUntilStopped()
    let first = await cache.take(from: video.id, keeping: [video.id])
    XCTAssertNotNil(first)
    let next = await cache.take(from: video.id, keeping: [video.id])
    XCTAssertNil(next, "one oversized packet fills the queue even when preroll releases a group")
    let ended = await cache.hasReachedEnd
    XCTAssertFalse(ended, "a full queue must stop reading before EOF")
  }
}
