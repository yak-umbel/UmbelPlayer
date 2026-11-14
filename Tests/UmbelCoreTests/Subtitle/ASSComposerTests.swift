import CoreGraphics
import XCTest
@testable import UmbelASSSupport
@testable import UmbelCore

final class ASSComposerTests: XCTestCase {
  /// A solid square of full coverage.
  private func square(
    x: Int, y: Int, size: Int = 4, color: UInt32, coverage: UInt8 = 255
  ) -> ASSImage {
    ASSImage(
      x: x, y: y, width: size, height: size, stride: size,
      coverage: [UInt8](repeating: coverage, count: size * size), color: color)
  }

  /// BGRA bytes of one pixel, premultiplied.
  private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return Array(data[offset..<offset + 4])
  }

  func testOverlappingImagesBecomeOneBitmap() {
    let bitmaps = ASSComposer.compose([
      square(x: 10, y: 10, color: 0x0000_0000),
      square(x: 12, y: 12, color: 0xFFFF_FF00),
    ])
    XCTAssertEqual(bitmaps.count, 1)
    XCTAssertEqual(bitmaps[0].frame, CGRect(x: 10, y: 10, width: 6, height: 6))
  }

  /// A sign at the top and dialogue at the bottom stay two small bitmaps
  /// rather than one the size of the picture.
  func testSeparateImagesStaySeparate() {
    let bitmaps = ASSComposer.compose([
      square(x: 0, y: 0, color: 0xFFFF_FF00),
      square(x: 100, y: 200, color: 0xFFFF_FF00),
    ])
    XCTAssertEqual(bitmaps.count, 2)
  }

  /// A third image can join two groups that did not touch each other.
  func testBridgingImageMergesGroups() {
    let bitmaps = ASSComposer.compose([
      square(x: 0, y: 0, color: 0xFFFF_FF00),
      square(x: 10, y: 0, color: 0xFFFF_FF00),
      square(x: 2, y: 0, size: 10, color: 0x0000_0000),
    ])
    XCTAssertEqual(bitmaps.count, 1)
  }

  /// libass colours are RGBA with transparency last; the output is
  /// premultiplied BGRA.
  func testColourAndTransparency() throws {
    // Red at half transparency: alpha 127, and red premultiplied by it.
    let bitmap = try XCTUnwrap(ASSComposer.compose([square(x: 0, y: 0, color: 0xFF00_0080)]).first)
    XCTAssertEqual(pixel(bitmap.image, x: 1, y: 1), [0, 0, 127, 127])
  }

  func testPartialCoverageScalesAlpha() throws {
    let bitmap = try XCTUnwrap(
      ASSComposer.compose([square(x: 0, y: 0, color: 0xFFFF_FF00, coverage: 51)]).first)
    XCTAssertEqual(pixel(bitmap.image, x: 0, y: 0), [51, 51, 51, 51])
  }

  /// Later images go on top: libass lists shadow, then outline, then fill.
  func testLaterImagesPaintOver() throws {
    let bitmap = try XCTUnwrap(ASSComposer.compose([
      square(x: 0, y: 0, size: 6, color: 0x0000_0000),
      square(x: 1, y: 1, size: 4, color: 0xFFFF_FF00),
    ]).first)
    XCTAssertEqual(pixel(bitmap.image, x: 2, y: 2), [255, 255, 255, 255], "fill over outline")
    XCTAssertEqual(pixel(bitmap.image, x: 0, y: 0), [0, 0, 0, 255], "outline shows at the edge")
  }

  func testNothingInNothingOut() {
    XCTAssertTrue(ASSComposer.compose([]).isEmpty)
  }
}
