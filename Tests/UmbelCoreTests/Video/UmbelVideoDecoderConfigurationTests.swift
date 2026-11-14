import XCTest
@testable import UmbelCore

final class UmbelVideoDecoderConfigurationTests: XCTestCase {
  /// Not asking is what it has been: hardware where it can, and FFmpeg's
  /// pick of threads where it cannot.
  func testTheDefaultAsksForNothingNew() {
    let configuration = UmbelVideoDecoderConfiguration()
    XCTAssertEqual(configuration.preference, .hardware)
    XCTAssertNil(configuration.softwareThreadCount)
    XCTAssertEqual(configuration, .init(preference: .hardware, softwareThreadCount: nil))
  }

  func testTheCountsAreTheOnesAHostCanChooseFrom() {
    XCTAssertEqual(UmbelVideoDecoderConfiguration.softwareThreadCounts, [1, 2, 4, 6, 8, 10, 12, 14, 16])
  }

  func testThoseCountsAreKept() {
    for count in UmbelVideoDecoderConfiguration.softwareThreadCounts {
      XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: count).softwareThreadCount, count)
    }
  }

  /// Between two counts: the lower, which delays and holds less.
  func testACountBetweenTwoIsBroughtDownToTheLower() {
    for (asked, kept) in [(3, 2), (5, 4), (7, 6), (9, 8), (11, 10), (13, 12), (15, 14)] {
      XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: asked).softwareThreadCount, kept, "\(asked)")
    }
  }

  func testCountsBeyondThemAreBroughtToTheNearestEnd() {
    XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: 0).softwareThreadCount, 1)
    XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: -4).softwareThreadCount, 1)
    XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: 17).softwareThreadCount, 16)
    XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: 18).softwareThreadCount, 16)
    XCTAssertEqual(UmbelVideoDecoderConfiguration(softwareThreadCount: .max).softwareThreadCount, 16)
  }

  func testACountSetLaterIsBroughtToOneOfThemToo() {
    var configuration = UmbelVideoDecoderConfiguration()
    configuration.softwareThreadCount = 64
    XCTAssertEqual(configuration.softwareThreadCount, 16)
    configuration.softwareThreadCount = 5
    XCTAssertEqual(configuration.softwareThreadCount, 4)
    configuration.softwareThreadCount = -1
    XCTAssertEqual(configuration.softwareThreadCount, 1)
    configuration.softwareThreadCount = nil
    XCTAssertNil(configuration.softwareThreadCount)
  }

  func testConfigurationsWithTheSameChoicesAreEqual() {
    XCTAssertEqual(
      UmbelVideoDecoderConfiguration(preference: .software, softwareThreadCount: 99),
      UmbelVideoDecoderConfiguration(preference: .software, softwareThreadCount: 16))
    XCTAssertNotEqual(
      UmbelVideoDecoderConfiguration(preference: .software),
      UmbelVideoDecoderConfiguration(preference: .hardware))
  }
}
