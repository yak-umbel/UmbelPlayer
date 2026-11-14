import CoreGraphics
import XCTest
import UmbelFFmpegSupport
@testable import UmbelCore

/// What a track says of its turn and of the size it is drawn at.
final class TrackRotationTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func videoDescription(
    width: Int = 128, height: Int = 64, pixelAspectRatio: Double = 1,
    rotation: UmbelVideoRotation, dynamicHDR: UmbelDynamicHDR? = nil
  ) -> UmbelTrack.VideoDescription {
    UmbelTrack.VideoDescription(
      width: width, height: height, nominalFrameRate: 10, pixelAspectRatio: pixelAspectRatio,
      dynamicHDR: dynamicHDR, rotation: rotation)
  }

  func testAQuarterTurnTradesTheDisplayWidthAndHeight() {
    let video = videoDescription(rotation: .clockwise90)
    XCTAssertEqual(video.displayWidth, 64)
    XCTAssertEqual(video.displayHeight, 128)
    XCTAssertEqual(video.width, 128, "stored pixels are as stored")
    XCTAssertEqual(video.height, 64, "stored pixels are as stored")
  }

  func testAHalfTurnKeepsTheDisplayShape() {
    let video = videoDescription(rotation: .clockwise180)
    XCTAssertEqual(video.displayWidth, 128)
    XCTAssertEqual(video.displayHeight, 64)
  }

  /// The pixel shape applies to the stored width first, then the axes trade
  /// places: 64×32 with pixels twice as wide is 128×32 shown, 32×128 turned.
  func testThePixelShapeComesBeforeTheTurn() {
    let upright = videoDescription(width: 64, height: 32, pixelAspectRatio: 2, rotation: .none)
    XCTAssertEqual(upright.displayWidth, 128)
    XCTAssertEqual(upright.displayHeight, 32)
    let turned = videoDescription(width: 64, height: 32, pixelAspectRatio: 2, rotation: .clockwise270)
    XCTAssertEqual(turned.displayWidth, 32)
    XCTAssertEqual(turned.displayHeight, 128)
  }

  /// The system shows profile 5 as stored, so what is drawn is not turned,
  /// whatever the stream declares; the declaration is still reported.
  func testTheSystemDisplayPathIsNotTurned() {
    let profile5 = UmbelDynamicHDR.dv(profile: 5, level: 6, compatibility: 0)
    let video = videoDescription(rotation: .clockwise90, dynamicHDR: profile5)
    XCTAssertEqual(video.rotation, .clockwise90)
    XCTAssertEqual(video.appliedRotation, UmbelVideoRotation.none)
    XCTAssertEqual(video.displayWidth, 128)
    XCTAssertEqual(video.displayHeight, 64)
    let baseLayer = UmbelDynamicHDR.dv(profile: 8, level: 6, compatibility: 4)
    XCTAssertEqual(videoDescription(rotation: .clockwise90, dynamicHDR: baseLayer).appliedRotation, .clockwise90)
  }

  func testTheMappingTakesTheStreamsDegrees() throws {
    func track(_ degrees: Int32) throws -> UmbelTrack {
      try XCTUnwrap(TrackMapping.track(from: FFmpegStreamInfo(
        index: 0, mediaType: .video, codecName: "h264", language: nil, title: nil,
        isDefault: true, isForced: false, width: 128, height: 64,
        frameRateNum: 10, frameRateDen: 1, channelCount: 0, sampleRate: 0, rotation: degrees)))
    }
    XCTAssertEqual(try track(0).video?.rotation, UmbelVideoRotation.none)
    XCTAssertEqual(try track(90).video?.rotation, .clockwise90)
    XCTAssertEqual(try track(270).video?.rotation, .clockwise270)
  }

  func testFixturesDeclareTheirTurnAndShowTheTurnedSize() async throws {
    let expected: [(name: String, rotation: UmbelVideoRotation, width: Int, height: Int)] = [
      ("rotation_none.mp4", .none, 128, 64), ("rotation_cw90.mp4", .clockwise90, 64, 128),
      ("rotation_cw180.mp4", .clockwise180, 128, 64), ("rotation_cw270.mp4", .clockwise270, 64, 128),
      ("rotation_flipped.mp4", .none, 128, 64), ("rotation_45.mp4", .none, 128, 64),
    ]
    for item in expected {
      let demux = DemuxSession(source: try UmbelFileSource(url: fixture(item.name)))
      try await demux.open()
      let tracks = await demux.tracks
      await demux.close()
      let video = try XCTUnwrap(tracks.first { $0.kind == .video }?.video, item.name)
      XCTAssertEqual(video.rotation, item.rotation, item.name)
      XCTAssertEqual(video.displayWidth, item.width, item.name)
      XCTAssertEqual(video.displayHeight, item.height, item.name)
    }
  }
}
