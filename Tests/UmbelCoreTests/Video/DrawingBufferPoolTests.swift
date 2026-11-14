import CoreVideo
import XCTest
@testable import UmbelCore

final class DrawingBufferPoolTests: XCTestCase {
  func testABufferHasTheSizeAndFormatAsked() throws {
    var pool = DrawingBufferPool()
    let buffer = try pool.buffer(width: 64, height: 32, format: kCVPixelFormatType_32BGRA)
    XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(buffer), 32)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
    XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
  }

  func testTheFormatFollowsTheLastBufferAndIsForgottenByAReset() throws {
    var pool = DrawingBufferPool()
    XCTAssertNil(pool.format)
    _ = try pool.buffer(width: 16, height: 16, format: kCVPixelFormatType_64RGBAHalf)
    XCTAssertEqual(pool.format, kCVPixelFormatType_64RGBAHalf)
    pool.reset()
    XCTAssertNil(pool.format)
  }

  func testAChangeOfSizeOrFormatGivesBuffersOfTheNewOne() throws {
    var pool = DrawingBufferPool()
    _ = try pool.buffer(width: 16, height: 16, format: kCVPixelFormatType_32BGRA)
    let wider = try pool.buffer(width: 32, height: 16, format: kCVPixelFormatType_32BGRA)
    XCTAssertEqual(CVPixelBufferGetWidth(wider), 32)
    let wide = try pool.buffer(width: 32, height: 16, format: kCVPixelFormatType_64RGBAHalf)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(wide), kCVPixelFormatType_64RGBAHalf)
    XCTAssertEqual(pool.format, kCVPixelFormatType_64RGBAHalf)
  }
}
