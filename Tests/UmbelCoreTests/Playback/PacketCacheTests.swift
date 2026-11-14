import CoreMedia
import XCTest
@testable import UmbelCore

final class PacketCacheTests: XCTestCase {
  private func packet(
    track: Int32, at seconds: Double, lasting duration: Double, keyframe: Bool = true
  ) -> DemuxPacket {
    DemuxPacket(
      trackID: UmbelTrack.ID(rawValue: track),
      data: Data(count: 16),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 600),
      duration: CMTime(seconds: duration, preferredTimescale: 600),
      isKeyframe: keyframe)
  }

  func testBufferedSecondsComesFromTheAudioTrack() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: UmbelTrack.ID(rawValue: 1))
    for index in 0..<10 {
      await cache.append(packet(track: 1, at: Double(index) * 0.1, lasting: 0.1))
      // Video packets do not count towards time: frames may be reordered,
      // and counted together the level would jump about.
      await cache.append(packet(track: 0, at: Double(index) * 0.04, lasting: 0.04))
    }
    let buffered = await cache.bufferedSeconds
    XCTAssertEqual(buffered, 1.0, accuracy: 0.001)
  }

  func testFullAtTargetAndPlayableAtStartThreshold() async {
    let configuration = BufferingConfiguration(
      startThreshold: 2, lowWatermark: 1, target: 3)
    let cache = PacketCache(
      configuration: configuration, measuredTrack: UmbelTrack.ID(rawValue: 1))

    await cache.append(packet(track: 1, at: 0, lasting: 0.5))
    var playable = await cache.hasEnoughToPlay
    XCTAssertFalse(playable, "half a second is not enough to start")

    await cache.append(packet(track: 1, at: 0.5, lasting: 1.6))
    playable = await cache.hasEnoughToPlay
    XCTAssertTrue(playable, "past the start threshold")
    var full = await cache.isFull
    XCTAssertFalse(full)

    await cache.append(packet(track: 1, at: 2.1, lasting: 1.0))
    full = await cache.isFull
    XCTAssertTrue(full, "reading stops at the target")
  }

  func testTakeReducesBufferedSeconds() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: UmbelTrack.ID(rawValue: 1))
    await cache.append(packet(track: 1, at: 0, lasting: 0.5))
    await cache.append(packet(track: 1, at: 0.5, lasting: 0.5))

    let first = await cache.take(from: UmbelTrack.ID(rawValue: 1), keeping: [])
    XCTAssertNotNil(first)
    let buffered = await cache.bufferedSeconds
    XCTAssertEqual(buffered, 0.5, accuracy: 0.001, "taking a packet takes its duration off")
  }

  func testFlushEmptiesEverything() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: UmbelTrack.ID(rawValue: 1))
    await cache.append(packet(track: 1, at: 0, lasting: 0.5))
    await cache.flush()
    let buffered = await cache.bufferedSeconds
    XCTAssertEqual(buffered, 0)
    let taken = await cache.take(from: UmbelTrack.ID(rawValue: 1), keeping: [])
    XCTAssertNil(taken)
  }

  /// A packet without a duration gets one from the gap to the next
  /// presentation time.
  ///
  /// Some containers leave duration out; without an estimate the level stays
  /// at zero and buffering decisions stop working altogether.
  func testEstimatesDurationWhenMissing() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: UmbelTrack.ID(rawValue: 1))
    await cache.append(
      DemuxPacket(
        trackID: UmbelTrack.ID(rawValue: 1), data: Data(count: 16),
        presentationTime: CMTime(seconds: 0, preferredTimescale: 600),
        decodeTime: .invalid, duration: .invalid, isKeyframe: true))
    await cache.append(
      DemuxPacket(
        trackID: UmbelTrack.ID(rawValue: 1), data: Data(count: 16),
        presentationTime: CMTime(seconds: 0.4, preferredTimescale: 600),
        decodeTime: .invalid, duration: .invalid, isKeyframe: true))

    let buffered = await cache.bufferedSeconds
    XCTAssertEqual(buffered, 0.4, accuracy: 0.001, "estimated from the gap in presentation times")
  }

  /// Once the content is all read, however little is cached, there is no
  /// buffering to report.
  func testEndOfContentMeansNoMoreBuffering() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: UmbelTrack.ID(rawValue: 1))
    await cache.markEndOfContent()
    let starving = await cache.isStarving
    XCTAssertFalse(starving, "at the end it is not running dry but finishing")
  }

  /// With nothing measured there is nothing to wait for.
  ///
  /// A level that can never rise would hold playback in buffering forever;
  /// that is what a session without an audio output used to get.
  func testNoMeasuredTrackNeverWaits() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: nil)
    await cache.append(packet(track: 0, at: 0, lasting: 0.04))
    let playable = await cache.hasEnoughToPlay
    let starving = await cache.isStarving
    XCTAssertTrue(playable)
    XCTAssertFalse(starving)
  }

  /// Resuming after a stall asks for more than starting does, but never more
  /// than the cache is allowed to hold — or it would wait forever.
  func testResumeThresholdIsCappedByTheTarget() async {
    let cache = PacketCache(
      configuration: BufferingConfiguration(
        startThreshold: 2, resumeThreshold: 5, lowWatermark: 1, target: 3),
      measuredTrack: UmbelTrack.ID(rawValue: 1))
    await cache.append(packet(track: 1, at: 0, lasting: 2.5))
    var resumable = await cache.hasEnoughToResume
    XCTAssertFalse(resumable)
    await cache.append(packet(track: 1, at: 2.5, lasting: 0.5))
    resumable = await cache.hasEnoughToResume
    XCTAssertTrue(resumable, "full at the target counts as enough")
  }

  // ── One queue per track ───────────────────────────────

  private let audio = UmbelTrack.ID(rawValue: 1)
  private let video = UmbelTrack.ID(rawValue: 0)
  private let otherAudio = UmbelTrack.ID(rawValue: 2)
  private let subtitle = UmbelTrack.ID(rawValue: 3)

  /// Each chain takes only its own track's packets, in the order read. That
  /// is what lets audio and video be fed separately: neither waits behind the
  /// other's packets.
  func testEachTrackIsTakenOnItsOwn() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio)
    await cache.append(packet(track: 1, at: 0, lasting: 0.1))
    await cache.append(packet(track: 0, at: 0, lasting: 0.04))
    await cache.append(packet(track: 0, at: 0.04, lasting: 0.04))
    await cache.append(packet(track: 1, at: 0.1, lasting: 0.1))

    let v1 = await cache.take(from: video, keeping: [audio, video])
    let v2 = await cache.take(from: video, keeping: [audio, video])
    let v3 = await cache.take(from: video, keeping: [audio, video])
    XCTAssertEqual([v1, v2].map { $0?.presentationTime.seconds }, [0, 0.04])
    XCTAssertNil(v3, "no third video packet, whatever audio is waiting")
    let a1 = await cache.take(from: audio, keeping: [audio, video])
    XCTAssertEqual(a1?.presentationTime.seconds, 0)
    let level = await cache.bufferedSeconds
    XCTAssertEqual(level, 0.1, accuracy: 0.001, "video packets never counted")
  }

  /// Nobody takes an unselected track, so its packets are dropped once the
  /// chain of its kind has moved past them. What is still ahead stays: a
  /// switch to that track can start from it.
  func testUnselectedTracksArePrunedBehindTheFeed() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio)
    for index in 0..<5 {
      let time = Double(index) * 0.1
      await cache.append(packet(track: 1, at: time, lasting: 0.1))
      await cache.append(packet(track: 2, at: time, lasting: 0.1))
    }
    _ = await cache.take(from: audio, keeping: [audio])
    _ = await cache.take(from: audio, keeping: [audio])
    _ = await cache.take(from: audio, keeping: [audio])   // at 0.2 s

    let next = await cache.take(from: otherAudio, keeping: [otherAudio])
    XCTAssertEqual(next?.presentationTime.seconds ?? -1, 0.2, accuracy: 0.001,
                   "switching now starts where the feed is, not from the stale head")
  }

  /// Subtitles are handed on up to where the leading chain has got to.
  func testSubtitlesAreTakenUpToATime() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio)
    await cache.append(packet(track: 3, at: 1, lasting: 2))
    await cache.append(packet(track: 3, at: 4, lasting: 2))
    let due = await cache.take(from: subtitle, upTo: CMTime(seconds: 3, preferredTimescale: 600))
    XCTAssertEqual(due.map(\.presentationTime.seconds), [1])
    let later = await cache.take(from: subtitle, upTo: CMTime(seconds: 5, preferredTimescale: 600))
    XCTAssertEqual(later.map(\.presentationTime.seconds), [4])
  }

  /// Three seconds of video at 25 frames a second, a keyframe every 25, and
  /// sound alongside; the first frame already taken.
  private func threeSecondsOfVideo() async -> PacketCache {
    let cache = PacketCache(configuration: .init(), measuredTrack: video)
    for frame in 0..<75 {
      let seconds = Double(frame) * 0.04
      await cache.append(packet(track: 0, at: seconds, lasting: 0.04, keyframe: frame % 25 == 0))
      await cache.append(packet(track: 1, at: seconds, lasting: 0.04))
    }
    _ = await cache.take(from: video, keeping: [audio, video])
    return cache
  }

  /// Very late video starts again from its last keyframe at or before the
  /// clock. What comes before it goes, and its share of the level with it;
  /// other tracks keep theirs.
  func testSkipsToTheLastKeyframeAtOrBeforeATime() async {
    let cache = await threeSecondsOfVideo()
    let dropped = await cache.skipToKeyframe(
      of: video, atOrBefore: CMTime(seconds: 2.3, preferredTimescale: 600))
    XCTAssertEqual(dropped, 49, "frames 1 to 49")
    let next = await cache.take(from: video, keeping: [audio, video])
    XCTAssertEqual(next?.presentationTime.seconds ?? 0, 2.0, accuracy: 0.001)
    let buffered = await cache.bufferedSeconds
    XCTAssertEqual(buffered, 24 * 0.04, accuracy: 0.001, "frames 51 to 74")
    let sound = await cache.take(from: audio, keeping: [audio, video])
    XCTAssertEqual(sound?.presentationTime.seconds ?? -1, 0, accuracy: 0.001)
  }

  /// Still inside the group of the next packet: nothing to start again from.
  func testNoKeyframeAheadSkipsNothing() async {
    let cache = await threeSecondsOfVideo()
    let dropped = await cache.skipToKeyframe(
      of: video, atOrBefore: CMTime(seconds: 0.9, preferredTimescale: 600))
    XCTAssertEqual(dropped, 0)
    let next = await cache.take(from: video, keeping: [audio, video])
    XCTAssertEqual(next?.presentationTime.seconds ?? 0, 0.04, accuracy: 0.001)
  }

  /// The keyframe is next anyway: nothing to drop.
  func testAKeyframeNextSkipsNothing() async {
    let cache = await threeSecondsOfVideo()
    for _ in 1..<25 { _ = await cache.take(from: video, keeping: [audio, video]) }
    let dropped = await cache.skipToKeyframe(
      of: video, atOrBefore: CMTime(seconds: 1.5, preferredTimescale: 600))
    XCTAssertEqual(dropped, 0)
  }

  /// At the end means read to the end and this track's queue empty — not
  /// every track's.
  func testEndIsPerTrack() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio)
    await cache.append(packet(track: 1, at: 0, lasting: 0.1))
    await cache.append(packet(track: 0, at: 0, lasting: 0.04))
    await cache.markEndOfContent()
    _ = await cache.take(from: video, keeping: [audio, video])
    let videoDone = await cache.isAtEnd(of: video)
    let audioDone = await cache.isAtEnd(of: audio)
    XCTAssertTrue(videoDone)
    XCTAssertFalse(audioDone)
  }
}
