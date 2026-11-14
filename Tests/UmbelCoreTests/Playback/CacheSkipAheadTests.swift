import CoreMedia
import XCTest
@testable import UmbelCore

/// A forward seek into what is read already keeps it: the queues move on to
/// the target, as reading after a seek would have them.
final class CacheSkipAheadTests: XCTestCase {
  private let video = UmbelTrack.ID(rawValue: 0)
  private let audio = UmbelTrack.ID(rawValue: 1)

  private func packet(
    _ track: UmbelTrack.ID, at seconds: Double, lasting duration: Double, keyframe: Bool = true
  ) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: 16),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 90_000),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 90_000),
      duration: CMTime(seconds: duration, preferredTimescale: 90_000),
      isKeyframe: keyframe)
  }

  /// Read from `start` to `end`: pictures at 25 a second with a keyframe
  /// every two seconds (the first one where the stream starts on it), sound
  /// in tenths of a second.
  private func cache(
    from start: Double = 0, to end: Double = 20, startingOnKeyframe: Bool = true,
    configuration: BufferingConfiguration = .init(target: 60)
  ) async -> PacketCache {
    let cache = PacketCache(configuration: configuration, measuredTrack: audio)
    for frame in 0..<Int(((end - start) * 25).rounded()) {
      let time = start + Double(frame) * 0.04
      let keyframe = frame % 50 == 0 && (startingOnKeyframe || frame > 0)
      await cache.append(packet(video, at: time, lasting: 0.04, keyframe: keyframe))
    }
    await append(audioFrom: start, to: end, into: cache)
    return cache
  }

  private func append(audioFrom start: Double, to end: Double, into cache: PacketCache) async {
    for index in 0..<Int(((end - start) * 10).rounded()) {
      await cache.append(packet(audio, at: start + Double(index) * 0.1, lasting: 0.1))
    }
  }

  private func firstTime(of track: UmbelTrack.ID, in cache: PacketCache) async -> Double? {
    await cache.take(from: track, keeping: [video, audio])?.presentationTime.seconds
  }

  private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

  func testPicturesStartAtTheKeyframeBeforeTheTargetAndSoundJustBeforeIt() async throws {
    let cache = await cache()
    let moved = await cache.skipAhead(to: at(5.55), video: video, audio: audio)
    XCTAssertTrue(moved)
    let picture = await firstTime(of: video, in: cache)
    XCTAssertEqual(try XCTUnwrap(picture), 4.0, accuracy: 0.001, "decoding starts at the keyframe")
    let sound = await firstTime(of: audio, in: cache)
    XCTAssertEqual(try XCTUnwrap(sound), 5.4, accuracy: 0.001, "a tenth of a second of warm-up before the target")
  }

  func testTheLevelCountsOnlyWhatIsKept() async {
    let cache = await cache()
    let bytesBefore = await cache.bufferedPacketBytes
    _ = await cache.skipAhead(to: at(5.55), video: video, audio: audio)
    let seconds = await cache.bufferedSeconds
    XCTAssertEqual(seconds, 20 - 5.4, accuracy: 0.01)
    let bytes = await cache.bufferedPacketBytes
    // 100 pictures before the keyframe at 4 s and 54 sound packets before 5.4 s went.
    XCTAssertEqual(bytesBefore - bytes, (100 + 54) * 16)
  }

  func testWithoutAKeyframeBeforeTheTargetNothingChanges() async {
    let cache = await cache(startingOnKeyframe: false)
    let moved = await cache.skipAhead(to: at(1.5), video: video, audio: audio)
    XCTAssertFalse(moved, "the keyframe the target needs was taken already")
    let seconds = await cache.bufferedSeconds
    XCTAssertEqual(seconds, 20, accuracy: 0.01)
    let picture = await firstTime(of: video, in: cache)
    XCTAssertEqual(picture ?? -1, 0, accuracy: 0.001)
  }

  func testPastWhatIsReadNothingChanges() async {
    let cache = await cache()
    let moved = await cache.skipAhead(to: at(25), video: video, audio: audio)
    XCTAssertFalse(moved, "reading on that far is slower than seeking there")
    let seconds = await cache.bufferedSeconds
    XCTAssertEqual(seconds, 20, accuracy: 0.01)
  }

  func testBeforeWhatIsLeftNothingChanges() async {
    let cache = await cache(from: 10)
    let moved = await cache.skipAhead(to: at(9), video: video, audio: audio)
    XCTAssertFalse(moved, "what was before has been taken; going back reads again")
  }

  func testSoundAloneMovesOnWithoutPictures() async throws {
    let cache = await cache()
    let moved = await cache.skipAhead(to: at(7.05), video: nil, audio: audio)
    XCTAssertTrue(moved)
    let sound = await firstTime(of: audio, in: cache)
    XCTAssertEqual(try XCTUnwrap(sound), 6.9, accuracy: 0.001)
    let picture = await firstTime(of: video, in: cache)
    XCTAssertEqual(picture ?? -1, 0, accuracy: 0.001, "a track not asked for is left alone")
  }

  func testNothingAskedForMovesNothing() async {
    let cache = await cache()
    let moved = await cache.skipAhead(to: at(5), video: nil, audio: nil)
    XCTAssertFalse(moved)
  }

  /// Sound dropped at the byte limit while another track was chosen is read
  /// again, even where timestamps going back make the queue look whole.
  func testSoundDroppedAtTheByteLimitIsReadAgain() async {
    let cache = PacketCache(
      configuration: .init(target: 60, maximumPacketBytes: 100 * 16), measuredTrack: audio)
    await cache.select([video], revision: 1)
    await append(audioFrom: 0, to: 6, into: cache)
    for frame in 0..<41 {
      await cache.append(packet(video, at: Double(frame) * 0.04, lasting: 0.04, keyframe: frame == 0))
    }
    let lost = await cache.dropped(audio, after: at(3))
    XCTAssertTrue(lost, "the unchosen sound went at the limit")
    await append(audioFrom: 3, to: 5, into: cache)
    let moved = await cache.skipAhead(to: at(4), video: nil, audio: audio)
    XCTAssertFalse(moved)
  }

  // ── Sound the system player asks for ────────────────

  /// The pipeline takes sound for the system player from the cache one
  /// packet at a time; stopped in the middle of that, the one it holds may be
  /// in the store or lost on the way. Putting it back, whichever it is, lets
  /// a seek go on without telling.
  private func onDemandCache() async -> PacketCache {
    let cache = PacketCache(configuration: .init(target: 60), measuredTrack: video)
    await cache.setMeasuredTrack(video, takenOnDemand: audio)
    await append(audioFrom: 0, to: 1, into: cache)
    return cache
  }

  func testThePacketLastTakenForTheSystemPlayersSoundComesBack() async {
    let cache = await onDemandCache()
    let first = await firstTime(of: audio, in: cache)
    XCTAssertEqual(try XCTUnwrap(first), 0, accuracy: 0.001)
    let head = await cache.putBackLast(of: audio)
    XCTAssertEqual(try XCTUnwrap(head).seconds, 0, accuracy: 0.001, "the queue starts with it again")
    let again = await firstTime(of: audio, in: cache)
    XCTAssertEqual(try XCTUnwrap(again), 0, accuracy: 0.001)
    let next = await firstTime(of: audio, in: cache)
    XCTAssertEqual(try XCTUnwrap(next), 0.1, accuracy: 0.001)
  }

  func testAPacketIsPutBackOnlyOnce() async {
    let cache = await onDemandCache()
    _ = await firstTime(of: audio, in: cache)
    _ = await cache.putBackLast(of: audio)
    let head = await cache.putBackLast(of: audio)
    XCTAssertEqual(try XCTUnwrap(head).seconds, 0, accuracy: 0.001)
    _ = await firstTime(of: audio, in: cache)
    let next = await firstTime(of: audio, in: cache)
    XCTAssertEqual(try XCTUnwrap(next), 0.1, accuracy: 0.001, "not twice")
  }

  func testPuttingBackCountsTheBytesAgain() async {
    let cache = await onDemandCache()
    _ = await firstTime(of: audio, in: cache)
    let taken = await cache.bufferedPacketBytes
    _ = await cache.putBackLast(of: audio)
    let back = await cache.bufferedPacketBytes
    XCTAssertEqual(back, taken + 16)
  }

  /// Sound decoded here is gone once taken: only what the system player
  /// asks for in its own time is kept in hand.
  func testSoundDecodedHereIsNotPutBack() async {
    let cache = await cache(to: 1)
    _ = await firstTime(of: audio, in: cache)
    let head = await cache.putBackLast(of: audio)
    XCTAssertEqual(try XCTUnwrap(head).seconds, 0.1, accuracy: 0.001)
  }

  func testSoundNoLongerTakenOnDemandIsNotPutBack() async {
    let cache = await onDemandCache()
    _ = await firstTime(of: audio, in: cache)
    await cache.setMeasuredTrack(video, takenOnDemand: nil)
    let head = await cache.putBackLast(of: audio)
    XCTAssertEqual(try XCTUnwrap(head).seconds, 0.1, accuracy: 0.001, "decoded here again: gone once taken")
  }

  func testEmptyingTheCacheForgetsIt() async {
    let cache = await onDemandCache()
    _ = await firstTime(of: audio, in: cache)
    await cache.flush()
    let head = await cache.putBackLast(of: audio)
    XCTAssertNil(head)
    let none = await firstTime(of: audio, in: cache)
    XCTAssertNil(none)
  }
}
