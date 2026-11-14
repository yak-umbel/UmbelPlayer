import XCTest
@testable import UmbelCore

final class VideoColorTests: XCTestCase {
  // Raw values of the colour space and range enumerations beneath. Integers
  // in Core, since the domain does not know those enumerations.
  private let unspecifiedSpace: Int32 = 2
  private let bt709Space: Int32 = 1
  private let bt601Space: Int32 = 5
  private let bt2020Space: Int32 = 9

  private let unspecifiedRange: Int32 = 0
  private let limitedRange: Int32 = 1
  private let fullRange: Int32 = 2

  func testBt709IsSupported() throws {
    let description = try VideoColorDescription.from(
      colorspace: bt709Space, range: limitedRange)
    XCTAssertEqual(description.matrix, .bt709)
    XCTAssertEqual(description.range, .limited)
  }

  /// Undeclared stays undeclared here; the renderer guesses from the size.
  func testUnspecifiedStaysUnspecified() throws {
    let description = try VideoColorDescription.from(
      colorspace: unspecifiedSpace, range: unspecifiedRange)
    XCTAssertEqual(description.matrix, .unspecified)
    XCTAssertEqual(description.range, .limited, "an undeclared range is taken as limited")
  }

  func testFullRangeIsRecognised() throws {
    let description = try VideoColorDescription.from(
      colorspace: bt709Space, range: fullRange)
    XCTAssertEqual(description.range, .full)
  }

  /// BT.601 comes as two codes, one per broadcast system; the matrix is the same.
  func testBt601IsSupported() throws {
    for code: Int32 in [5, 6] {
      let description = try VideoColorDescription.from(colorspace: code, range: limitedRange)
      XCTAssertEqual(description.matrix, .bt601, "colorspace=\(code)")
    }
  }

  func testBt2020IsSupported() throws {
    let description = try VideoColorDescription.from(colorspace: bt2020Space, range: limitedRange)
    XCTAssertEqual(description.matrix, .bt2020)
  }

  /// Declared but not supported: YCgCo, BT.2020 constant luminance, ICtCp
  /// (DV P5). Drawn as BT.709 they would come out in wrong
  /// colours, which is harder to trace than an error.
  func testOtherDeclaredMatricesStillThrow() {
    for code: Int32 in [8, 10, 14] {
      XCTAssertThrowsError(
        try VideoColorDescription.from(colorspace: code, range: limitedRange), "colorspace=\(code)"
      ) { error in
        guard case UmbelError.unsupportedColorMatrix = error else {
          return XCTFail("expected unsupportedColorMatrix, got \(error)")
        }
      }
    }
  }

  /// FFmpeg's codes: 16 is SMPTE ST 2084 (PQ), 18 ARIB STD-B67 (HLG); the
  /// rest, BT.709's own and BT.2020's 10- and 12-bit ones among them, are SDR.
  func testTransferFunction() throws {
    let expected: [Int32: UmbelTransferFunction] = [16: .pq, 18: .hlg, 1: .sdr, 14: .sdr, 2: .sdr]
    for (code, transfer) in expected {
      let description = try VideoColorDescription.from(
        colorspace: bt2020Space, range: limitedRange, transfer: code, primaries: 9)
      XCTAssertEqual(description.transfer, transfer, "transfer=\(code)")
    }
  }

  func testPrimaries() throws {
    let expected: [Int32: UmbelColorPrimaries] = [9: .bt2020, 1: .bt709, 2: .bt709, 6: .bt709]
    for (code, primaries) in expected {
      let description = try VideoColorDescription.from(
        colorspace: bt709Space, range: limitedRange, transfer: 1, primaries: code)
      XCTAssertEqual(description.primaries, primaries, "primaries=\(code)")
    }
  }

  /// An undeclared matrix is guessed from the size: wider than 1279 or
  /// taller than 576 is high definition, BT.709; anything smaller is
  /// standard definition, BT.601.
  func testUndeclaredMatrixIsGuessedFromTheSize() throws {
    let undeclared = try VideoColorDescription.from(colorspace: unspecifiedSpace, range: limitedRange)
    XCTAssertEqual(undeclared.matrix(forWidth: 720, height: 576), .bt601)
    XCTAssertEqual(undeclared.matrix(forWidth: 352, height: 288), .bt601)
    XCTAssertEqual(undeclared.matrix(forWidth: 1280, height: 720), .bt709)
    XCTAssertEqual(undeclared.matrix(forWidth: 960, height: 720), .bt709)
    let declared = try VideoColorDescription.from(colorspace: bt709Space, range: limitedRange)
    XCTAssertEqual(declared.matrix(forWidth: 352, height: 288), .bt709, "a declared matrix stands")
  }

  func testUnsupportedMatrixIsNotRetryable() {
    XCTAssertFalse(UmbelError.unsupportedColorMatrix("bt2020").isRetryable)
  }

  func testRenderUnavailableIsRetryable() {
    XCTAssertTrue(UmbelError.videoRenderUnavailable(reason: "no Metal device").isRetryable)
  }
}
