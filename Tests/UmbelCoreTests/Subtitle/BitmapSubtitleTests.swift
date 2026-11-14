import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

final class BitmapSubtitleTests: XCTestCase {
  /// A 2×1 bitmap: one opaque white pixel, one transparent.
  private func event(canvasWidth: Int, canvasHeight: Int) -> FFmpegSubtitle {
    let bitmap = FFmpegSubtitleBitmap(
      x: 10, y: 20, width: 2, height: 1, pixels: Data([255, 255, 255, 255, 0, 0, 0, 0]))
    return FFmpegSubtitle(
      startMicroseconds: 0, endMicroseconds: nil, assLines: [], bitmaps: [bitmap],
      canvasWidth: canvasWidth, canvasHeight: canvasHeight)
  }

  private func cues(_ subtitle: FFmpegSubtitle, fallback: CGSize?) -> [UmbelSubtitleCue] {
    BitmapSubtitle.cues(from: subtitle, start: .zero, end: nil, fallbackCanvas: fallback)
  }

  func testTheStreamsCanvasComesFirst() throws {
    let image = try XCTUnwrap(
      cues(event(canvasWidth: 100, canvasHeight: 50), fallback: CGSize(width: 1, height: 1))
        .first?.image)
    XCTAssertEqual(image.relativeFrame, CGRect(x: 0.1, y: 0.4, width: 0.02, height: 0.02))
  }

  /// A stream that does not state its canvas is placed on the video.
  func testFallsBackToTheVideoSize() throws {
    let image = try XCTUnwrap(
      cues(event(canvasWidth: 0, canvasHeight: 0), fallback: CGSize(width: 200, height: 100))
        .first?.image)
    XCTAssertEqual(image.relativeFrame, CGRect(x: 0.05, y: 0.2, width: 0.01, height: 0.01))
  }

  func testWithoutAnyCanvasNothingCanBePlaced() {
    XCTAssertTrue(cues(event(canvasWidth: 0, canvasHeight: 0), fallback: nil).isEmpty)
  }

  /// The pixels arrive as premultiplied BGRA and must read back as such.
  func testImageKeepsThePixels() throws {
    let image = try XCTUnwrap(
      cues(event(canvasWidth: 100, canvasHeight: 50), fallback: nil).first?.image?.image)
    XCTAssertEqual(image.width, 2)
    XCTAssertEqual(image.height, 1)
    XCTAssertEqual(image.alphaInfo, .premultipliedFirst)
    let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
    XCTAssertEqual(Array(bytes.prefix(8)), [255, 255, 255, 255, 0, 0, 0, 0])
  }

  /// Equality follows the image object, so a renderer's "same as last time"
  /// check holds while one event stays up.
  func testCuesFromOneEventAreEqualOnlyToThemselves() {
    let subtitle = event(canvasWidth: 100, canvasHeight: 50)
    let first = cues(subtitle, fallback: nil)
    XCTAssertEqual(first, first)
    XCTAssertNotEqual(first, cues(subtitle, fallback: nil), "a new image is a new picture")
  }
}
