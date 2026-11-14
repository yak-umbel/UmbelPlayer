import CoreMedia
import XCTest
@testable import UmbelCore

final class UmbelTrackTests: XCTestCase {
  private func videoTrack(id: Int32 = 0) -> UmbelTrack {
    UmbelTrack(
      id: UmbelTrack.ID(rawValue: id),
      kind: .video,
      codecName: "h264",
      language: "und",
      title: nil,
      isDefault: true,
      isForced: false,
      video: UmbelTrack.VideoDescription(width: 1920, height: 1080, nominalFrameRate: 25),
      audio: nil
    )
  }

  func testVideoTrackCarriesVideoDescriptionOnly() {
    let track = videoTrack()
    XCTAssertEqual(track.kind, .video)
    XCTAssertNotNil(track.video)
    XCTAssertNil(track.audio)
  }

  func testTracksWithSameIDAreEqual() {
    XCTAssertEqual(videoTrack(id: 3), videoTrack(id: 3))
    XCTAssertNotEqual(videoTrack(id: 3), videoTrack(id: 4))
  }

  func testIDIsHashable() {
    let ids: Set<UmbelTrack.ID> = [.init(rawValue: 1), .init(rawValue: 1), .init(rawValue: 2)]
    XCTAssertEqual(ids.count, 2)
  }

  func testKindCoversExactlyThreeCases() {
    XCTAssertEqual(Set(UmbelTrack.Kind.allCases), [.video, .audio, .subtitle])
  }
}

final class DemuxPacketTests: XCTestCase {
  func testPacketCarriesTimingAndKeyframeFlag() {
    let packet = DemuxPacket(
      trackID: UmbelTrack.ID(rawValue: 0),
      data: Data([0x00, 0x01]),
      presentationTime: CMTime(value: 100, timescale: 1000),
      decodeTime: CMTime(value: 90, timescale: 1000),
      duration: CMTime(value: 40, timescale: 1000),
      isKeyframe: true
    )
    XCTAssertEqual(packet.data.count, 2)
    XCTAssertTrue(packet.isKeyframe)
    XCTAssertEqual(packet.presentationTime.seconds, 0.1, accuracy: 0.0001)
  }

  func testMissingTimestampsAreInvalidNotZero() {
    let packet = DemuxPacket(
      trackID: UmbelTrack.ID(rawValue: 0),
      data: Data(),
      presentationTime: .invalid,
      decodeTime: .invalid,
      duration: .invalid,
      isKeyframe: false
    )
    // Zero and "none" have to be told apart: zero is a valid first timestamp.
    XCTAssertFalse(packet.presentationTime.isValid)
    XCTAssertNotEqual(packet.presentationTime, .zero)
  }
}
