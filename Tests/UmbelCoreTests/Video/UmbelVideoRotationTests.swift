import CoreGraphics
import XCTest
@testable import UmbelCore

final class UmbelVideoRotationTests: XCTestCase {
  func testTheFourRightAnglesMapAndNothingElseDoes() {
    XCTAssertEqual(UmbelVideoRotation(clockwiseDegrees: 0), UmbelVideoRotation.none)
    XCTAssertEqual(UmbelVideoRotation(clockwiseDegrees: 90), .clockwise90)
    XCTAssertEqual(UmbelVideoRotation(clockwiseDegrees: 180), .clockwise180)
    XCTAssertEqual(UmbelVideoRotation(clockwiseDegrees: 270), .clockwise270)
    for other: Int32 in [45, 91, 360, -90] {
      XCTAssertEqual(UmbelVideoRotation(clockwiseDegrees: other), UmbelVideoRotation.none, "\(other)")
    }
  }

  func testOnlyQuarterTurnsSwapTheAxes() {
    XCTAssertFalse(UmbelVideoRotation.none.swapsAxes)
    XCTAssertTrue(UmbelVideoRotation.clockwise90.swapsAxes)
    XCTAssertFalse(UmbelVideoRotation.clockwise180.swapsAxes)
    XCTAssertTrue(UmbelVideoRotation.clockwise270.swapsAxes)
  }

  func testTurningASizeSwapsWidthAndHeightForQuarterTurns() {
    let size = CGSize(width: 128, height: 64)
    XCTAssertEqual(UmbelVideoRotation.none.turned(size), size)
    XCTAssertEqual(UmbelVideoRotation.clockwise90.turned(size), CGSize(width: 64, height: 128))
    XCTAssertEqual(UmbelVideoRotation.clockwise180.turned(size), size)
    XCTAssertEqual(UmbelVideoRotation.clockwise270.turned(size), CGSize(width: 64, height: 128))
  }
}
