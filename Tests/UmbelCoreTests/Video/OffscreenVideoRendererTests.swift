import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

final class OffscreenVideoRendererTests: XCTestCase {
  private func makeRendererOrSkip() throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let pipeline = try MetalPipeline(device: device)
    return OffscreenVideoRenderer(
      pipeline: pipeline,
      capacity: 3,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600)
    )
  }

  private func frame(
    luma: UInt8, cb: UInt8, cr: UInt8, seconds: Double = 0
  ) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(
      width: 64, height: 64, luma: luma, cb: cb, cr: cr)!
    return VideoFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      pixelBuffer: buffer, width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .limited)
    )
  }

  private func prepared(
    _ renderer: OffscreenVideoRenderer, range: UmbelColorRange = .limited
  ) async throws {
    try await renderer.prepare(
      width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: range))
  }

  /// Pure white in limited range: luma 235, chroma at the centre.
  func testWhiteRendersWhite() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    try await renderer.enqueue(frame(luma: 235, cb: 128, cr: 128))
    _ = try await renderer.presentFrame(at: .zero)

    let pixel = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertGreaterThan(pixel.r, 240)
    XCTAssertGreaterThan(pixel.g, 240)
    XCTAssertGreaterThan(pixel.b, 240)
  }

  /// Pure black in limited range: luma 16, chroma at the centre.
  func testBlackRendersBlack() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    try await renderer.enqueue(frame(luma: 16, cb: 128, cr: 128))
    _ = try await renderer.presentFrame(at: .zero)

    let pixel = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertLessThan(pixel.r, 12)
    XCTAssertLessThan(pixel.g, 12)
    XCTAssertLessThan(pixel.b, 12)
  }

  /// Pure red in BT.709 limited range is about Y=63, Cb=102, Cr=240. The
  /// expected value is worked out **independently** from the matrix, not
  /// taken from the code under test — that would prove only itself.
  func testRedRendersRed() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    try await renderer.enqueue(frame(luma: 63, cb: 102, cr: 240))
    _ = try await renderer.presentFrame(at: .zero)

    let pixel = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertGreaterThan(pixel.r, 200, "red is near full")
    XCTAssertLessThan(pixel.g, 60, "green is low")
    XCTAssertLessThan(pixel.b, 60, "blue is low")
  }

  /// Chroma planes crossed (Cb and Cr swapped) draw red as blue. This
  /// catches that.
  func testSwappedChromaProducesBlueNotRed() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    try await renderer.enqueue(frame(luma: 63, cb: 240, cr: 102))
    _ = try await renderer.presentFrame(at: .zero)

    let pixel = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertGreaterThan(pixel.b, pixel.r,
                         "with Cb and Cr swapped it turns blue; still red means the planes are crossed")
  }

  func testFullRangeWhiteUsesDifferentLumaValue() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer, range: .full)
    let buffer = VideoFrame.makeTestPixelBuffer(
      width: 64, height: 64, luma: 255, cb: 128, cr: 128)!
    try await renderer.enqueue(VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .full)))
    _ = try await renderer.presentFrame(at: .zero)

    let pixel = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertGreaterThan(pixel.r, 240)
  }

  func testPresentReturnsNilWhenNothingIsDue() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    // Present a frame first — "keep showing the last frame" needs a last
    // frame. Without one, the head is drawn however far off; see
    // VideoFrameQueue.
    try await renderer.enqueue(frame(luma: 128, cb: 128, cr: 128, seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)

    try await renderer.enqueue(frame(luma: 128, cb: 128, cr: 128, seconds: 5))
    let presented = try await renderer.presentFrame(at: .zero)
    XCTAssertNil(presented, "nothing is presented while the head is still in the future")
  }

  func testPresentReportsDroppedFrames() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    for index in 0..<3 {
      try await renderer.enqueue(
        frame(luma: 128, cb: 128, cr: 128, seconds: Double(index) * 0.04))
    }
    let presented = try await renderer.presentFrame(
      at: CMTime(seconds: 0.08, preferredTimescale: 600))
    XCTAssertEqual(presented?.droppedFrames, 2)
  }
}
