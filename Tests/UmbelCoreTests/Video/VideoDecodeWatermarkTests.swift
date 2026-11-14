import CoreMedia
import XCTest
@testable import UmbelCore

final class VideoDecodeWatermarkTests: XCTestCase {
  private func time(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 25) }

  func testInitialMissingDecodeTimesCannotReleaseFutureReferencePictures() throws {
    var watermark = VideoDecodeWatermark()
    for _ in 0..<2 {
      for pts in [0, 16, 8, 4] {
        let accepted = try watermark.accept(presentation: time(Int64(pts)), decode: .invalid)
        XCTAssertFalse(accepted.isValid, "missing DTS must not be replaced with PTS")
      }
      XCTAssertEqual(try watermark.accept(presentation: time(2), decode: time(0)), time(0))
      XCTAssertEqual(try watermark.accept(presentation: time(1), decode: time(1)), time(1))
      XCTAssertEqual(try watermark.accept(presentation: time(3), decode: time(2)), time(2))
      watermark.reset()
    }
  }

  func testEstablishedDecodeOrderRejectsMissingOrReversingTimes() throws {
    var watermark = VideoDecodeWatermark()
    _ = try watermark.accept(presentation: time(8), decode: time(3))
    for dts in [CMTime.invalid, .indefinite, .positiveInfinity, time(2)] {
      XCTAssertThrowsError(try watermark.accept(presentation: time(9), decode: dts))
    }
    XCTAssertThrowsError(try watermark.accept(presentation: time(2), decode: time(4)))
    XCTAssertThrowsError(try watermark.accept(presentation: .invalid, decode: time(4)))
    XCTAssertEqual(try watermark.accept(presentation: time(9), decode: time(4)), time(4))
  }
}
