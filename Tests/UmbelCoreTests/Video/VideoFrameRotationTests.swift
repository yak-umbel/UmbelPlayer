import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

final class VideoFrameRotationTests: XCTestCase {
  private let color = VideoColorDescription(matrix: .bt709, range: .limited)

  private func frame(
    width: Int, height: Int, pixelAspectRatio: Double = 1, rotation: UmbelVideoRotation
  ) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(width: width, height: height, luma: 126, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: width, height: height, color: color,
      pixelAspectRatio: pixelAspectRatio, rotation: rotation)
  }

  func testAFrameIsNotTurnedUnlessItIsTold() {
    let plain = VideoFrame(
      presentationTime: .zero,
      pixelBuffer: VideoFrame.makeTestPixelBuffer(width: 8, height: 8, luma: 16, cb: 128, cr: 128)!,
      width: 8, height: 8, color: color)
    XCTAssertEqual(plain.rotation, UmbelVideoRotation.none)
  }

  /// Pixels twice as wide: 64×32 stored is 128×32 shown; turned a quarter,
  /// 32×128 — not 128×32, and not the stored 64×32 turned.
  func testTheDisplaySizeWidensForThePixelShapeThenTurns() {
    XCTAssertEqual(frame(width: 64, height: 32, pixelAspectRatio: 2, rotation: .none).displaySize,
                   CGSize(width: 128, height: 32))
    XCTAssertEqual(frame(width: 64, height: 32, pixelAspectRatio: 2, rotation: .clockwise90).displaySize,
                   CGSize(width: 32, height: 128))
    XCTAssertEqual(frame(width: 64, height: 32, pixelAspectRatio: 2, rotation: .clockwise180).displaySize,
                   CGSize(width: 128, height: 32))
  }

  /// For subtitle layout: the stored pixels as shown, not widened.
  func testTheOrientedPixelSizeTurnsButIsNotWidened() {
    XCTAssertEqual(frame(width: 64, height: 32, pixelAspectRatio: 2, rotation: .clockwise270).orientedPixelSize,
                   CGSize(width: 32, height: 64))
    XCTAssertEqual(frame(width: 64, height: 32, pixelAspectRatio: 2, rotation: .none).orientedPixelSize,
                   CGSize(width: 64, height: 32))
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// Decoded from a file, the frame carries what the track says.
  func testDecodedFramesCarryTheTracksRotation() async throws {
    for (name, rotation) in [
      ("rotation_none.mp4", UmbelVideoRotation.none), ("rotation_cw90.mp4", .clockwise90),
      ("rotation_cw180.mp4", .clockwise180), ("rotation_cw270.mp4", .clockwise270),
      ("rotation_flipped.mp4", .none),
    ] {
      let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
      try await demux.open()
      addTeardownBlock { await demux.close() }
      let tracks = await demux.tracks
      let video = try XCTUnwrap(tracks.first { $0.kind == .video }, name)
      let session = VideoDecodeSession(
        decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
      addTeardownBlock { await session.close() }
      var first: VideoFrame?
      while first == nil, let packet = try await demux.nextPacket() {
        guard packet.trackID == video.id else { continue }
        first = try await session.decode(packet).first
      }
      if first == nil { first = try await session.drain().first }
      let decoded = try XCTUnwrap(first, name)
      XCTAssertEqual(decoded.rotation, rotation, name)
      XCTAssertEqual(decoded.rotation, video.video?.rotation, "frame and track agree: \(name)")
    }
  }
}
