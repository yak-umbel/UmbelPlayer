import XCTest
@testable import UmbelFFmpegSupport

final class FFmpegErrorCodeTests: XCTestCase {
  func testEndOfFileIsRecognised() {
    XCTAssertEqual(FFmpegErrorCode.classify(FFmpegErrorCode.endOfFileRaw), .endOfFile)
  }

  func testInvalidDataMapsToUnsupportedContainer() {
    XCTAssertEqual(FFmpegErrorCode.classify(FFmpegErrorCode.invalidDataRaw), .invalidData)
  }

  func testInterruptedIsRecognised() {
    XCTAssertEqual(FFmpegErrorCode.classify(FFmpegErrorCode.exitRaw), .interrupted)
  }

  func testUnknownNegativeCodeFallsBackToIO() {
    XCTAssertEqual(FFmpegErrorCode.classify(-987654), .io(-987654))
  }

  func testNonNegativeIsNotAnError() {
    XCTAssertNil(FFmpegErrorCode.classifyIfError(0))
    XCTAssertNil(FFmpegErrorCode.classifyIfError(42))
  }

  /// These constants are C macros worked out again in Swift. Worked out
  /// wrong, this test raises the alarm before the end-to-end tests do.
  func testRawConstantsMatchKnownValues() {
    // FFERRTAG('E','O','F',' ') = -(0x20464F45)
    XCTAssertEqual(FFmpegErrorCode.endOfFileRaw, -541_478_725)
    // FFERRTAG('I','N','D','A') = -(0x41444E49)
    XCTAssertEqual(FFmpegErrorCode.invalidDataRaw, -1_094_995_529)
  }
}
