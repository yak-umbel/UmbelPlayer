import XCTest
@testable import UmbelFFmpegSupport

/// A stream's display matrix as a container declares it: nine 32-bit values,
/// the upper left 2×2 block in 16.16 fixed point. The values below are what
/// a muxer writes for each rotation.
final class FFmpegDisplayRotationTests: XCTestCase {
  private let one: Int32 = 65_536

  private func matrix(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) -> [Int32] {
    [a, b, 0, c, d, 0, 0, 0, 1 << 30]
  }

  private func degrees(_ matrix: [Int32]) -> Int32 {
    FFmpegDisplayRotation.clockwiseDegrees(matrix: matrix)
  }

  func testTheIdentityIsNotTurned() {
    XCTAssertEqual(degrees(matrix(one, 0, 0, one)), 0)
  }

  /// A muxer asked for 270° counter-clockwise writes the first of these: the
  /// picture is turned a quarter clockwise to be shown upright.
  func testRightAnglesAreCountedClockwise() {
    XCTAssertEqual(degrees(matrix(0, one, -one, 0)), 90)
    XCTAssertEqual(degrees(matrix(-one, 0, 0, -one)), 180)
    XCTAssertEqual(degrees(matrix(0, -one, one, 0)), 270)
  }

  /// A horizontal flip is a matrix the angle alone reads as a half turn. It
  /// is shown as stored.
  func testAFlipIsNotATurn() {
    XCTAssertEqual(degrees(matrix(-one, 0, 0, one)), 0)
    XCTAssertEqual(degrees(matrix(one, 0, 0, -one)), 0)
    XCTAssertEqual(degrees(matrix(0, one, one, 0)), 0, "a quarter turn and a flip")
  }

  func testOtherAnglesAreNotTurns() {
    XCTAssertEqual(degrees(matrix(46_340, -46_340, 46_340, 46_340)), 0, "45°")
    XCTAssertEqual(degrees(matrix(2_287, -65_496, 65_496, 2_287)), 0, "88°, two degrees off a right angle")
  }

  /// Fixed point rounds: 89.5° is a right angle to the precision a matrix has.
  func testARightAngleToWithinADegreeIsOne() {
    XCTAssertEqual(degrees(matrix(571, -65_533, 65_533, 571)), 270)
  }

  func testAMatrixThatIsNoTurnAtAllIsNotATurn() {
    XCTAssertEqual(degrees(matrix(0, 0, 0, 0)), 0)
    XCTAssertEqual(degrees([1, 2, 3]), 0, "not nine values")
  }
}
