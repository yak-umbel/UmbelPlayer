import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

/// A host's renderer that only notes what it was prepared with.
private actor PreparationRecorder: VideoRenderer {
  private(set) var prepared: (width: Int, height: Int, pixelAspectRatio: Double)?
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {
    prepared = (width, height, pixelAspectRatio)
  }
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// What a renderer is prepared with before the first frame, as its protocol
/// documents: stored pixels and their shape, except for a quarter-turned
/// track, which comes in the turned shape at a pixel shape of 1.
final class RendererPreparationTests: XCTestCase {
  private func track(
    width: Int, height: Int, pixelAspectRatio: Double = 1,
    rotation: UmbelVideoRotation, dynamicHDR: UmbelDynamicHDR? = nil
  ) -> UmbelTrack {
    UmbelTrack(
      id: UmbelTrack.ID(rawValue: 0), kind: .video, codecName: "h264", language: nil, title: nil,
      isDefault: true, isForced: false,
      video: UmbelTrack.VideoDescription(
        width: width, height: height, nominalFrameRate: 25, pixelAspectRatio: pixelAspectRatio,
        dynamicHDR: dynamicHDR, rotation: rotation),
      audio: nil)
  }

  private func prepared(for track: UmbelTrack) async throws -> (width: Int, height: Int, pixelAspectRatio: Double) {
    let recorder = PreparationRecorder()
    try await recorder.prepare(for: track)
    let values = await recorder.prepared
    return try XCTUnwrap(values)
  }

  func testUnturnedTracksComeAsStoredPixelsWithTheirShape() async throws {
    let upright = try await prepared(for: track(width: 128, height: 64, rotation: .none))
    XCTAssertEqual(upright.width, 128)
    XCTAssertEqual(upright.height, 64)
    XCTAssertEqual(upright.pixelAspectRatio, 1)
    let wide = try await prepared(for: track(width: 64, height: 32, pixelAspectRatio: 2, rotation: .none))
    XCTAssertEqual(wide.width, 64)
    XCTAssertEqual(wide.height, 32)
    XCTAssertEqual(wide.pixelAspectRatio, 2)
    let halfTurn = try await prepared(for: track(width: 128, height: 64, rotation: .clockwise180))
    XCTAssertEqual(halfTurn.width, 128, "a half turn keeps the shape")
    XCTAssertEqual(halfTurn.height, 64)
  }

  func testAQuarterTurnedTrackComesInTheTurnedShape() async throws {
    let turned = try await prepared(for: track(width: 128, height: 64, rotation: .clockwise90))
    XCTAssertEqual(turned.width, 64)
    XCTAssertEqual(turned.height, 128)
    XCTAssertEqual(turned.pixelAspectRatio, 1)
    let wideTurned = try await prepared(
      for: track(width: 64, height: 32, pixelAspectRatio: 2, rotation: .clockwise270))
    XCTAssertEqual(wideTurned.width, 32, "widened first, then turned")
    XCTAssertEqual(wideTurned.height, 128)
    XCTAssertEqual(wideTurned.pixelAspectRatio, 1)
  }

  /// The system shows profile 5 as stored, whatever the stream declares.
  func testTheSystemDisplayPathComesAsStored() async throws {
    let profile5 = UmbelDynamicHDR.dv(profile: 5, level: 6, compatibility: 0)
    let system = try await prepared(
      for: track(width: 128, height: 64, rotation: .clockwise90, dynamicHDR: profile5))
    XCTAssertEqual(system.width, 128)
    XCTAssertEqual(system.height, 64)
  }
}
