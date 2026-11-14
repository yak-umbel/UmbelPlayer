import FFmpeg
import XCTest
@testable import UmbelFFmpegSupport

final class VideoFormatDescriptionTests: XCTestCase {
  func testDescribesAllComponentDepthsBeforeConversion() throws {
    let format = try XCTUnwrap(FFmpegVideoFormat(pixelFormatCode: AV_PIX_FMT_YUV444P12LE.rawValue))
    XCTAssertEqual(format.componentDepths, [12, 12, 12])
    XCTAssertEqual(format.chromaSubsampling, "4:4:4")
    XCTAssertEqual(format.storageBits, 16)
    XCTAssertFalse(format.isRGB)
  }

  func testUnknownFormatDoesNotInventEightBit() {
    XCTAssertNil(FFmpegVideoFormat(pixelFormatCode: AV_PIX_FMT_NONE.rawValue))
  }

  func testRGBIsNotReportedAsSubsampledYUV() throws {
    let format = try XCTUnwrap(FFmpegVideoFormat(pixelFormatCode: AV_PIX_FMT_RGB48LE.rawValue))
    XCTAssertEqual(format.componentDepths, [16, 16, 16])
    XCTAssertNil(format.chromaSubsampling)
    XCTAssertTrue(format.isRGB)
  }
}
