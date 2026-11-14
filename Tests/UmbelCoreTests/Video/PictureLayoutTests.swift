import CoreGraphics
import XCTest
@testable import UmbelCore

/// Where the picture goes, and the part of it that shows.
final class PictureLayoutTests: XCTestCase {
  private let wide = CGSize(width: 1920, height: 800)   // 2.4:1
  private let screen = CGSize(width: 1600, height: 1000) // 16:10

  func testFitPutsAllOfItInWithBarsAndShowsAllOfIt() {
    let layout = PictureFit.layout(picture: wide, in: screen, geometry: .standard)
    XCTAssertEqual(layout.picture, CGRect(x: 0, y: 166, width: 1600, height: 667))
    XCTAssertEqual(layout.visible, layout.picture)
  }

  func testFillCoversTheOutputAndShowsTheOutput() {
    let layout = PictureFit.layout(
      picture: wide, in: screen, geometry: PictureGeometry(aspectRatio: nil, scaling: .fill))
    XCTAssertEqual(layout.picture.height, 1000)
    XCTAssertEqual(layout.picture.width, 2400)
    XCTAssertEqual(layout.picture.minX, -400)
    XCTAssertEqual(layout.visible, CGRect(origin: .zero, size: screen))
  }

  func testAnAspectRatioReshapesThePictureByItsHeight() {
    let shape = PictureFit.shape(of: CGSize(width: 640, height: 480), aspectRatio: 2)
    XCTAssertEqual(shape, CGSize(width: 960, height: 480))
    XCTAssertEqual(PictureFit.shape(of: CGSize(width: 640, height: 480), aspectRatio: nil),
                   CGSize(width: 640, height: 480))
  }

  /// A window resized, or going full screen, while filling: laid out again
  /// for the new size, what shows is the new output.
  func testTheLayoutFollowsANewOutputSize() {
    let fill = PictureGeometry(aspectRatio: nil, scaling: .fill)
    let small = PictureFit.layout(picture: wide, in: CGSize(width: 800, height: 500), geometry: fill)
    XCTAssertEqual(small.visible, CGRect(x: 0, y: 0, width: 800, height: 500))
    XCTAssertEqual(small.picture.height, 500)
  }

  func testAnEmptyOutputOrPictureLaysNothingOut() {
    let empty = PictureFit.layout(picture: wide, in: .zero, geometry: .standard)
    XCTAssertEqual(empty, PictureLayout(picture: .zero, visible: .zero))
    let none = PictureFit.layout(picture: .zero, in: screen, geometry: .standard)
    XCTAssertEqual(none, PictureLayout(picture: .zero, visible: .zero))
  }
}
