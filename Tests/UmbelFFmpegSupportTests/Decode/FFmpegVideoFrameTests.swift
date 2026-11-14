import CoreVideo
import XCTest
@testable import UmbelFFmpegSupport

final class FFmpegVideoFrameTests: XCTestCase {
  private func makeBuffer() -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, 16, 16,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
    return buffer!
  }

  func testCarriesGeometryAndTiming() {
    let frame = FFmpegVideoFrame(
      pixelBuffer: makeBuffer(), width: 16, height: 16,
      pts: 1000, timeBaseNum: 1, timeBaseDen: 25_000,
      colorspace: 1, colorRange: 1, wasHardwareDecoded: true)
    XCTAssertEqual(frame.width, 16)
    XCTAssertEqual(frame.pts, 1000)
    XCTAssertEqual(frame.timeBaseDen, 25_000)
    XCTAssertTrue(frame.wasHardwareDecoded)
  }

  func testCarriesColourDeclaration() {
    let frame = FFmpegVideoFrame(
      pixelBuffer: makeBuffer(), width: 16, height: 16,
      pts: 0, timeBaseNum: 1, timeBaseDen: 1,
      colorspace: 9, colorRange: 2, wasHardwareDecoded: false)
    XCTAssertEqual(frame.colorspace, 9, "the colour space comes out raw, for the layer above to judge")
    XCTAssertEqual(frame.colorRange, 2)
  }
}
