import CoreMedia
import XCTest
@testable import UmbelCore

/// What the level is measured by when it changes, and sound that another
/// player takes at its own pace.
final class PacketCacheMeasuringTests: XCTestCase {
  private let video = UmbelTrack.ID(rawValue: 0)
  private let audio = UmbelTrack.ID(rawValue: 1)

  private func packet(_ track: UmbelTrack.ID, at seconds: Double, lasting duration: Double) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: 16),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 600),
      duration: CMTime(seconds: duration, preferredTimescale: 600), isKeyframe: true)
  }

  /// Measured by another track, the level is that track's: the picture's
  /// packets from before, which nobody may ever take, no longer hold
  /// reading back.
  func testALevelMeasuredByAnotherTrackIsThatTracksOwn() async {
    let cache = PacketCache(configuration: .init(target: 3), measuredTrack: video)
    for index in 0..<4 {
      await cache.append(packet(video, at: Double(index), lasting: 1))
      await cache.append(packet(audio, at: Double(index) * 0.1, lasting: 0.1))
    }
    var full = await cache.isFull
    XCTAssertTrue(full)
    await cache.setMeasuredTrack(audio)
    let level = await cache.bufferedSeconds
    XCTAssertEqual(level, 0.4, accuracy: 0.001)
    full = await cache.isFull
    XCTAssertFalse(full)
    await cache.append(packet(audio, at: 0.4, lasting: 0.1))
    let more = await cache.bufferedSeconds
    XCTAssertEqual(more, 0.5, accuracy: 0.001, "counted from where that track stands")
  }

  /// The system player takes the sound as it asks for it. With none of it
  /// left to hand over, reading goes on however full the picture's side:
  /// the player may be waiting, and the picture may not be taken at all —
  /// its decoding suspended, or nothing shown in the background.
  func testSoundTakenOnDemandKeepsReadingGoingOnceNoneIsQueued() async {
    let cache = PacketCache(configuration: .init(target: 3), measuredTrack: video)
    await cache.setMeasuredTrack(video, gatesPlayback: true, takenOnDemand: audio)
    for index in 0..<4 { await cache.append(packet(video, at: Double(index), lasting: 1)) }
    var full = await cache.isFull
    XCTAssertFalse(full, "no sound queued")
    await cache.append(packet(audio, at: 0, lasting: 0.1))
    full = await cache.isFull
    XCTAssertTrue(full)
    _ = await cache.take(from: audio, keeping: [audio, video])
    full = await cache.isFull
    XCTAssertFalse(full, "all of it handed over")
  }

  func testDecodedSoundDoesNotKeepReadingGoing() async {
    let cache = PacketCache(configuration: .init(target: 3), measuredTrack: video)
    for index in 0..<4 { await cache.append(packet(video, at: Double(index), lasting: 1)) }
    let full = await cache.isFull
    XCTAssertTrue(full)
  }
}
