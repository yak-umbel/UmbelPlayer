import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import UmbelCore

final class VideoOrientationTests: XCTestCase {
  private func render(_ orientation: SplitOrientation) async throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let pipeline = try MetalPipeline(device: device)
    let renderer = OffscreenVideoRenderer(
      pipeline: pipeline, capacity: 3,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))

    let color = VideoColorDescription(matrix: .bt709, range: .limited)
    try await renderer.prepare(width: 64, height: 64, color: color)
    let buffer = VideoFrame.makeSplitPixelBuffer(
      width: 64, height: 64, orientation: orientation)!
    try await renderer.enqueue(VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer,
      width: 64, height: 64, color: color))
    _ = try await renderer.presentFrame(at: .zero)
    return renderer
  }

  /// Bright above, dark below. Rendered upside down, this fails.
  func testTopBrightStaysOnTop() async throws {
    let renderer = try await render(.topBright)
    let top = try await renderer.readAveragePixel(inRegion: .topHalf)
    let bottom = try await renderer.readAveragePixel(inRegion: .bottomHalf)
    XCTAssertGreaterThan(Int(top.g), Int(bottom.g) + 100,
                         "the top is clearly brighter than the bottom; the other way, texture y is wrong")
  }

  /// Bright on the left, dark on the right. Rendered mirrored, this fails.
  func testLeftBrightStaysOnLeft() async throws {
    let renderer = try await render(.leftBright)
    let left = try await renderer.readAveragePixel(inRegion: .leftHalf)
    let right = try await renderer.readAveragePixel(inRegion: .rightHalf)
    XCTAssertGreaterThan(Int(left.g), Int(right.g) + 100,
                         "the left is clearly brighter than the right; the other way, it is mirrored")
  }

  func testSplitBufferHasExpectedLumaValues() throws {
    let buffer = try XCTUnwrap(
      VideoFrame.makeSplitPixelBuffer(width: 8, height: 8, orientation: .topBright))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let plane = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
      .assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    XCTAssertEqual(plane[0], 235, "the first row is in the top half, bright")
    XCTAssertEqual(plane[7 * bytesPerRow], 16, "the last row is in the bottom half, dark")
  }
}
