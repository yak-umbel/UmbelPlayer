import CoreMedia
import XCTest
@testable import UmbelCore

/// A stream's frame period from when its frames are shown: taken only when
/// two spacings in a row agree.
final class FramePeriodEstimatorTests: XCTestCase {
  /// A 90 kHz time, rounded: `CMTime(seconds:)` cuts 0.12 s down to 10799 ticks.
  private func shown(_ seconds: Double) -> CMTime {
    CMTime(value: Int64((seconds * 90_000).rounded()), timescale: 90_000)
  }

  private func estimate(_ times: [Double]) -> FramePeriodEstimator {
    var estimator = FramePeriodEstimator()
    for time in times { estimator.observe(shown(time)) }
    return estimator
  }

  func testNothingUntilTwoSpacingsAgree() throws {
    XCTAssertNil(estimate([]).period)
    XCTAssertNil(estimate([0]).period)
    XCTAssertNil(estimate([0, 0.04]).period, "one spacing")
    XCTAssertEqual(try XCTUnwrap(estimate([0, 0.04, 0.08]).period).seconds, 0.04, accuracy: 1e-6)
  }

  /// 29.97 frames a second in a millisecond time base: 33, 33, 34 ms.
  func testMillisecondRoundingStillAgrees() throws {
    let period = try XCTUnwrap(estimate([0, 0.033, 0.066, 0.100]).period)
    XCTAssertEqual(period.seconds, 0.0335, accuracy: 0.0006)
  }

  /// A frame lost: 40, 80, 40, 40. The 80 agrees with nothing and changes
  /// nothing; two 40s after it do.
  func testALostFrameDoesNotChangeThePeriod() throws {
    XCTAssertNil(estimate([0, 0.04, 0.12]).period)
    let learned = estimate([0, 0.04, 0.08, 0.16])
    XCTAssertEqual(try XCTUnwrap(learned.period).seconds, 0.04, accuracy: 1e-6, "kept")
    let after = estimate([0, 0.04, 0.12, 0.16, 0.20])
    XCTAssertEqual(try XCTUnwrap(after.period).seconds, 0.04, accuracy: 1e-6, "found again")
  }

  func testSpacingsOutsideTheRangeAreNotTaken() {
    XCTAssertNil(estimate([0, 0.005, 0.010, 0.015]).period, "too short for a frame")
    XCTAssertNil(estimate([0, 0.5, 1.0, 1.5]).period, "too long for a frame")
  }

  /// Backwards, repeated, and times that are no time at all break the run.
  func testTimesThatGoBackOrAreNotNumbersBreakTheRun() {
    XCTAssertNil(estimate([0, 0.04, 0.04, 0.08]).period, "repeated")
    XCTAssertNil(estimate([0, 0.04, 0.02, 0.06]).period, "backwards")
    var estimator = FramePeriodEstimator()
    for time in [shown(0), shown(0.04), .invalid, shown(0.08), shown(0.12)] {
      estimator.observe(time)
    }
    XCTAssertNil(estimator.period, "the invalid time split the run into pieces of one spacing")
  }

  /// A seek: the period is the stream's and stays; the time of the frame
  /// before and the spacing before it no longer lead to anything.
  func testForgettingThePositionKeepsThePeriodButNotWhatCameBefore() throws {
    var estimator = estimate([0, 0.04, 0.08])
    estimator.forgetPosition()
    XCTAssertEqual(try XCTUnwrap(estimator.period).seconds, 0.04, accuracy: 1e-6)
    // 41.5 ms after the frame before the seek would agree with the 40 ms
    // before it and move the period; forgotten, it counts for nothing.
    estimator.observe(shown(0.1215))
    XCTAssertEqual(try XCTUnwrap(estimator.period).seconds, 0.04, accuracy: 1e-6)
    estimator.observe(shown(0.1630))
    XCTAssertEqual(try XCTUnwrap(estimator.period).seconds, 0.04, accuracy: 1e-6, "one spacing since")
  }

  func testACadenceChangeIsFollowedAfterTwoNewSpacings() throws {
    let times = [0, 0.04, 0.08, 0.12, 0.1534, 0.1868]
    XCTAssertEqual(try XCTUnwrap(estimate(Array(times.prefix(5))).period).seconds, 0.04, accuracy: 1e-6, "one new spacing")
    XCTAssertEqual(try XCTUnwrap(estimate(times).period).seconds, 0.0334, accuracy: 1e-4)
  }

  func testOneOddSpacingKeepsThePeriod() throws {
    let period = try XCTUnwrap(estimate([0, 0.04, 0.08, 0.12, 0.14, 0.18, 0.22]).period)
    XCTAssertEqual(period.seconds, 0.04, accuracy: 1e-6)
  }
}
