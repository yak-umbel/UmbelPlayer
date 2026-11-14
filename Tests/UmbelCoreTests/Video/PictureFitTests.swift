import CoreGraphics
import XCTest
@testable import UmbelCore

final class PictureFitTests: XCTestCase {
  func testWiderOutputGetsBarsLeftAndRight() {
    let rect = PictureFit.rect(fitting: CGSize(width: 1920, height: 1080), in: CGSize(width: 2400, height: 1080))
    XCTAssertEqual(rect, CGRect(x: 240, y: 0, width: 1920, height: 1080))
  }

  func testTallerOutputGetsBarsTopAndBottom() {
    let rect = PictureFit.rect(fitting: CGSize(width: 320, height: 240), in: CGSize(width: 640, height: 640))
    XCTAssertEqual(rect, CGRect(x: 0, y: 80, width: 640, height: 480))
  }

  /// Upscaled as well as down: the picture fills the output however small
  /// the video is.
  func testSmallVideoIsScaledUp() {
    let rect = PictureFit.rect(fitting: CGSize(width: 160, height: 90), in: CGSize(width: 2880, height: 1620))
    XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 2880, height: 1620))
  }

  /// Whole pixels: a fractional edge would blur the picture's border.
  func testEdgesLandOnWholePixels() {
    let rect = PictureFit.rect(fitting: CGSize(width: 1000, height: 333), in: CGSize(width: 501, height: 501))
    XCTAssertEqual(rect, rect.integral)
  }

  func testEmptySizesGiveNothing() {
    XCTAssertEqual(PictureFit.rect(fitting: .zero, in: CGSize(width: 10, height: 10)), .zero)
    XCTAssertEqual(PictureFit.rect(fitting: CGSize(width: 10, height: 10), in: .zero), .zero)
  }
}
