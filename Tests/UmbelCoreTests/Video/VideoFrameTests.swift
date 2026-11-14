import CoreMedia
import CoreVideo
import XCTest
@testable import UmbelCore

final class VideoFrameTests: XCTestCase {
  func testMakeTestPixelBufferHasExpectedGeometry() throws {
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 64, height: 32, luma: 128, cb: 128, cr: 128))
    XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(buffer), 32)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer),
                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                   "always biplanar video range")
    XCTAssertEqual(CVPixelBufferGetPlaneCount(buffer), 2)
  }

  func testMakeTestPixelBufferWritesBothPlanes() throws {
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 200, cb: 90, cr: 30))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
      .assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(luma[0], 200)

    let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
      .assumingMemoryBound(to: UInt8.self)
    // Interleaved: Cb, then Cr.
    XCTAssertEqual(chroma[0], 90)
    XCTAssertEqual(chroma[1], 30)
  }

  func testFrameCarriesTimeAndGeometry() throws {
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 8, height: 8, luma: 16, cb: 128, cr: 128))
    let frame = VideoFrame(
      presentationTime: CMTime(value: 1, timescale: 25),
      pixelBuffer: buffer,
      width: 8,
      height: 8,
      color: VideoColorDescription(matrix: .bt709, range: .limited)
    )
    XCTAssertEqual(frame.presentationTime.seconds, 0.04, accuracy: 0.0001)
    XCTAssertEqual(frame.width, 8)
    XCTAssertEqual(frame.color.matrix, .bt709)
  }
}
