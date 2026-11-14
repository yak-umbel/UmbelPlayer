import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// A 128×64 picture bright in its top-left quadrant, drawn at each rotation:
/// the bright corner must land where the turn puts it.
final class VideoRotationRenderingTests: XCTestCase {
  private let color = VideoColorDescription(matrix: .bt709, range: .limited)
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func device() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return device
  }

  private func frame(rotation: UmbelVideoRotation) -> VideoFrame {
    let buffer = VideoFrame.makeSplitPixelBuffer(width: 128, height: 64, orientation: .topLeftBright)!
    return VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 128, height: 64, color: color,
      rotation: rotation)
  }

  /// Rotation, the shape drawn at, and which quadrant is bright: 0 top-left,
  /// 1 top-right, 2 bottom-right, 3 bottom-left.
  private let cases: [(UmbelVideoRotation, width: Int, height: Int, bright: Int)] = [
    (.none, 128, 64, 0), (.clockwise90, 64, 128, 1),
    (.clockwise180, 128, 64, 2), (.clockwise270, 64, 128, 3),
  ]

  func testTheBrightCornerLandsWhereTheTurnPutsIt() async throws {
    let pipeline = try MetalPipeline(device: try device())
    for (rotation, width, height, bright) in cases {
      let renderer = OffscreenVideoRenderer(pipeline: pipeline, capacity: 3, tolerance: tolerance)
      try await renderer.prepare(width: width, height: height, color: color)
      try await renderer.enqueue(frame(rotation: rotation))
      _ = try await renderer.presentFrame(at: .zero)
      let centres = [
        (width / 4, height / 4), (3 * width / 4, height / 4),
        (3 * width / 4, 3 * height / 4), (width / 4, 3 * height / 4),
      ]
      for (index, point) in centres.enumerated() {
        let pixel = try await renderer.readPixel(x: point.0, y: point.1)
        if index == bright {
          XCTAssertGreaterThan(pixel.g, 200, "\(rotation): quadrant \(index) should be bright")
        } else {
          XCTAssertLessThan(pixel.g, 60, "\(rotation): quadrant \(index) should be dark")
        }
      }
    }
  }

  /// Snapshots and timeline previews draw through the same encoder.
  func testASnapshotOfATurnedFrameIsTurned() throws {
    let turned = frame(rotation: .clockwise90)
    let image = try FrameSnapshot.image(
      of: turned, size: turned.displaySize, subtitles: [], device: try device())
    XCTAssertEqual(image.width, 64)
    XCTAssertEqual(image.height, 128)
    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
    func green(_ x: Int, _ y: Int) -> Int { Int(bytes[y * image.bytesPerRow + x * 4 + 1]) }
    XCTAssertGreaterThan(green(48, 32), 200, "top-right")
    XCTAssertLessThan(green(16, 32), 60, "top-left")
    XCTAssertLessThan(green(48, 96), 60, "bottom-right")
    XCTAssertLessThan(green(16, 96), 60, "bottom-left")
  }
}
