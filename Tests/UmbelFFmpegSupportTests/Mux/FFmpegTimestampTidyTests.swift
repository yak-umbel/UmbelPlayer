import XCTest
@testable import UmbelFFmpegSupport

final class FFmpegTimestampTidyTests: XCTestCase {
  private let none = FFmpegTimestampTidy.noTimestamp

  func testAPacketWithNoTimeAtAllIsLeftOut() {
    var tidy = FFmpegTimestampTidy(streams: 1)
    XCTAssertNil(tidy.tidy(stream: 0, dts: none, pts: none))
  }

  func testOneTimeStandsInForTheOther() throws {
    var tidy = FFmpegTimestampTidy(streams: 2)
    let fromPresentation = try XCTUnwrap(tidy.tidy(stream: 0, dts: none, pts: 100))
    XCTAssertEqual(fromPresentation.dts, 100)
    XCTAssertEqual(fromPresentation.pts, 100)
    let fromDecoding = try XCTUnwrap(tidy.tidy(stream: 1, dts: 40, pts: none))
    XCTAssertEqual(fromDecoding.dts, 40)
    XCTAssertEqual(fromDecoding.pts, 40)
  }

  func testTimesThatRiseAreLeftAsTheyAre() throws {
    var tidy = FFmpegTimestampTidy(streams: 1)
    let first = try XCTUnwrap(tidy.tidy(stream: 0, dts: 10, pts: 30))
    let second = try XCTUnwrap(tidy.tidy(stream: 0, dts: 20, pts: 20))
    XCTAssertEqual(first.dts, 10)
    XCTAssertEqual(first.pts, 30)
    XCTAssertEqual(second.dts, 20)
    XCTAssertEqual(second.pts, 20)
  }

  /// A container refuses a decoding time that does not come after the last of
  /// its stream; it is put just after, and its presentation time with it, so
  /// that the gap between the two is kept.
  func testATimeThatDoesNotRiseIsPutJustAfterTheLast() throws {
    var tidy = FFmpegTimestampTidy(streams: 1)
    _ = tidy.tidy(stream: 0, dts: 100, pts: 120)
    let same = try XCTUnwrap(tidy.tidy(stream: 0, dts: 100, pts: 130))
    XCTAssertEqual(same.dts, 101)
    XCTAssertEqual(same.pts, 131)
    let behind = try XCTUnwrap(tidy.tidy(stream: 0, dts: 60, pts: 90))
    XCTAssertEqual(behind.dts, 102)
    XCTAssertEqual(behind.pts, 132)
    let onward = try XCTUnwrap(tidy.tidy(stream: 0, dts: 200, pts: 200))
    XCTAssertEqual(onward.dts, 200, "once it rises again it is left alone")
  }

  func testAPresentationTimeIsNeverBeforeItsDecodingTime() throws {
    var tidy = FFmpegTimestampTidy(streams: 1)
    let packet = try XCTUnwrap(tidy.tidy(stream: 0, dts: 50, pts: 40))
    XCTAssertEqual(packet.dts, 50)
    XCTAssertEqual(packet.pts, 50)
  }

  func testEachStreamKeepsItsOwnCount() throws {
    var tidy = FFmpegTimestampTidy(streams: 2)
    _ = tidy.tidy(stream: 0, dts: 500, pts: 500)
    let other = try XCTUnwrap(tidy.tidy(stream: 1, dts: 10, pts: 10))
    XCTAssertEqual(other.dts, 10, "another stream's time is not this one's last")
  }
}
