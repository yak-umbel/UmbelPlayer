import CoreMedia
import XCTest
@testable import UmbelCore

final class PrerollFilterTests: XCTestCase {
  private let video = UmbelTrack.ID(rawValue: 0)
  private let audio = UmbelTrack.ID(rawValue: 1)
  private let subtitle = UmbelTrack.ID(rawValue: 2)

  private func packet(
    _ track: UmbelTrack.ID, _ seconds: Double, key: Bool = false, lasting duration: Double = 0.04
  ) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data([1]),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 1000),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 1000),
      duration: CMTime(seconds: duration, preferredTimescale: 1000), isKeyframe: key)
  }

  private func filter(target: Double = 5) -> PrerollFilter {
    PrerollFilter(target: CMTime(seconds: target, preferredTimescale: 1000), video: video, audio: audio)
  }

  private func times(_ packets: [DemuxPacket]) -> [Double] {
    packets.map(\.presentationTime.seconds)
  }

  /// Only the group of pictures holding the target reaches the decoder, so
  /// reading from earlier costs bytes but no extra decoding.
  func testKeepsOnlyTheGroupOfPicturesHoldingTheTarget() {
    var filter = filter()
    XCTAssertEqual(times(filter.admit(packet(video, 1.0))), [], "no key frame yet: undecodable")
    XCTAssertEqual(times(filter.admit(packet(video, 2.0, key: true))), [])
    XCTAssertEqual(times(filter.admit(packet(video, 3.0))), [])
    XCTAssertEqual(times(filter.admit(packet(video, 4.0, key: true))), [], "a later key frame replaces the group")
    XCTAssertEqual(times(filter.admit(packet(video, 4.5))), [])
    XCTAssertEqual(times(filter.admit(packet(video, 5.2))), [4.0, 4.5, 5.2])
    XCTAssertEqual(times(filter.admit(packet(video, 4.9))), [4.9], "past the target, everything passes")
  }

  /// A key frame at or after the target starts cleanly; the held group is
  /// not needed.
  func testKeyFrameAtTheTargetDropsTheHeldGroup() {
    var filter = filter()
    _ = filter.admit(packet(video, 4.0, key: true))
    _ = filter.admit(packet(video, 4.5))
    XCTAssertEqual(times(filter.admit(packet(video, 5.0, key: true))), [5.0])
  }

  /// Audio well before the target never enters the cache: counted there, it
  /// would make the buffer look fuller than it is. A tenth of a second is kept
  /// for decoders that need to warm up.
  func testDropsAudioEndingWellBeforeTheTarget() {
    var filter = filter()
    XCTAssertEqual(times(filter.admit(packet(audio, 3.0, lasting: 0.5))), [])
    XCTAssertEqual(times(filter.admit(packet(audio, 4.85, lasting: 0.1))), [4.85], "ends within the warm-up")
    XCTAssertEqual(times(filter.admit(packet(audio, 5.1, lasting: 0.1))), [5.1])
  }

  func testSubtitlesAlwaysPass() {
    var filter = filter()
    XCTAssertEqual(times(filter.admit(packet(subtitle, 1.0, lasting: 6))), [1.0])
  }

  /// Content ending before the target still hands over what it held, so the
  /// last picture can show.
  func testDrainReleasesTheHeldGroup() {
    var filter = filter()
    _ = filter.admit(packet(video, 4.0, key: true))
    _ = filter.admit(packet(video, 4.5))
    XCTAssertEqual(times(filter.drain()), [4.0, 4.5])
  }

  func testFinishesOnceBothChainsReachTheTarget() {
    var filter = filter()
    XCTAssertFalse(filter.isFinished)
    _ = filter.admit(packet(video, 5.0, key: true))
    XCTAssertFalse(filter.isFinished, "audio has not arrived yet")
    _ = filter.admit(packet(audio, 5.0))
    XCTAssertTrue(filter.isFinished)

    var silent = PrerollFilter(
      target: CMTime(seconds: 5, preferredTimescale: 1000), video: video, audio: nil)
    _ = silent.admit(packet(video, 5.0, key: true))
    XCTAssertTrue(silent.isFinished, "no audio to wait for")
  }
}
