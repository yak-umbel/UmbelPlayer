import CoreVideo
import XCTest
@testable import UmbelCore

final class VideoSignalDescriptionTests: XCTestCase {
  func testP010StorageIsNotItsEffectiveDepth() {
    let actual = VideoPixelDescription(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    XCTAssertEqual(actual.effectiveBits, 10)
    XCTAssertEqual(actual.storageBits, 16)
    XCTAssertEqual(actual.chromaSubsampling, "4:2:0")
  }

  func testUnknownCVFormatRetainsUnknownPrecision() {
    let actual = VideoPixelDescription(cvFormat: 0)
    XCTAssertNil(actual.effectiveBits)
    XCTAssertNil(actual.storageBits)
  }

  func testOriginalSDRCurveAndPrimariesRemainObservable() throws {
    let color = try VideoColorDescription.from(colorspace: 1, range: 2, transfer: 13, primaries: 12)
    XCTAssertEqual(color.transfer, .sdr)
    XCTAssertEqual(color.transferCode, 13)
    XCTAssertEqual(color.primariesCode, 12)
    XCTAssertEqual(color.matrixCode, 1)
    XCTAssertEqual(color.rangeCode, 2)
  }
}
