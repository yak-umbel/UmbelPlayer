import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

/// Geometry and presence only, never pixel values: the fonts on a CI machine
/// are not the fonts here.
final class UmbelSubtitleRendererTests: XCTestCase {
  private let size = CGSize(width: 1280, height: 720)

  private func cue(
    _ text: String, alignment: UmbelSubtitleAlignment = .bottomCenter,
    bold: Bool = false, start: Double = 0
  ) -> UmbelSubtitleCue {
    UmbelSubtitleCue(
      start: CMTime(seconds: start, preferredTimescale: 1000), end: nil,
      runs: [.init(text: text, isBold: bold)], alignment: alignment)
  }

  private func render(_ cues: [UmbelSubtitleCue]) -> [UmbelSubtitleBitmap] {
    UmbelSubtitleRenderer().render(cues, in: size).bitmaps
  }

  /// Pixels with any coverage. A bitmap of nothing but transparency would
  /// pass every geometric check and show nothing.
  private func inkedPixels(_ image: CGImage) -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return 0 }
    return stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 }.count
  }

  func testBottomCentreSitsLowAndCentred() throws {
    let bitmap = try XCTUnwrap(render([cue("bottom line")]).first)
    XCTAssertGreaterThan(bitmap.frame.midY, size.height / 2)
    XCTAssertEqual(bitmap.frame.midX, size.width / 2, accuracy: 2)
    XCTAssertLessThanOrEqual(bitmap.frame.maxY, size.height)
    XCTAssertGreaterThan(inkedPixels(bitmap.image), 100)
  }

  func testTopAlignmentSitsHigh() throws {
    let bitmap = try XCTUnwrap(render([cue("top line", alignment: .topCenter)]).first)
    XCTAssertLessThan(bitmap.frame.midY, size.height / 2)
    XCTAssertGreaterThanOrEqual(bitmap.frame.minY, 0)
  }

  func testLeftAlignmentStartsAtTheMargin() throws {
    let bitmap = try XCTUnwrap(render([cue("left", alignment: .bottomLeft)]).first)
    // The default left margin is 10/384 of the width; the outline pads a little.
    XCTAssertEqual(bitmap.frame.minX, size.width * 10 / 384, accuracy: 6)
  }

  /// The ASS size is the font's full height, as in libass and VSFilter, so
  /// the text is noticeably shorter than a bitmap of that many em.
  func testFontSizeFollowsThePictureHeight() throws {
    let small = try XCTUnwrap(
      UmbelSubtitleRenderer().render([cue("Hg")], in: CGSize(width: 640, height: 360)).bitmaps.first)
    let large = try XCTUnwrap(render([cue("Hg")]).first)
    XCTAssertEqual(large.frame.height / small.frame.height, 2, accuracy: 0.25)
  }

  /// One line is as tall as the requested size: 16/288 of 720 is 40 pixels,
  /// with the outline padding on top. Reading the size as an em square would
  /// make it about a fifth taller.
  func testOneLineIsAsTallAsTheRequestedSize() throws {
    let bitmap = try XCTUnwrap(render([cue("Hg")]).first)
    let padding = ceil(720.0 / 288) + 1
    XCTAssertEqual(bitmap.frame.height - 2 * padding, 40, accuracy: 3)
  }

  func testLongTextWrapsWithinTheMargins() throws {
    let short = try XCTUnwrap(render([cue("short")]).first)
    let long = try XCTUnwrap(render([cue(String(repeating: "a very long subtitle line ", count: 12))]).first)
    XCTAssertLessThanOrEqual(long.frame.width, size.width)
    XCTAssertGreaterThan(long.frame.height, short.frame.height * 1.8, "wrapped onto more lines")
  }

  /// Two cues at the same position stack instead of overprinting; the later
  /// one moves away from the edge, as in libass.
  func testCuesAtTheSamePositionStack() throws {
    let bitmaps = render([cue("first", start: 0), cue("second", start: 1)])
    XCTAssertEqual(bitmaps.count, 2)
    XCTAssertFalse(bitmaps[0].frame.intersects(bitmaps[1].frame))
    XCTAssertLessThan(bitmaps[1].frame.maxY, bitmaps[0].frame.maxY, "second goes above")
  }

  func testBoldIsWider() throws {
    let regular = try XCTUnwrap(render([cue("Weight test")]).first)
    let bold = try XCTUnwrap(render([cue("Weight test", bold: true)]).first)
    XCTAssertGreaterThan(bold.frame.width, regular.frame.width)
  }

  /// Glyphs the requested font lacks come from the system's fallback fonts.
  func testChineseTextHasInk() throws {
    let bitmap = try XCTUnwrap(render([cue("中文字幕不缺字")]).first)
    XCTAssertGreaterThan(inkedPixels(bitmap.image), 500)
  }

  func testSameInputIsNotLaidOutAgain() {
    let renderer = UmbelSubtitleRenderer()
    let cues = [cue("steady")]
    let first = renderer.render(cues, in: size)
    let second = renderer.render(cues, in: size)
    XCTAssertTrue(first.isChanged)
    XCTAssertFalse(second.isChanged)
    XCTAssertTrue(first.bitmaps[0].image === second.bitmaps[0].image, "the same image, not a new one")

    let resized = renderer.render(cues, in: CGSize(width: 640, height: 360))
    XCTAssertTrue(resized.isChanged)
    let cleared = renderer.render([], in: CGSize(width: 640, height: 360))
    XCTAssertTrue(cleared.isChanged)
    XCTAssertTrue(cleared.bitmaps.isEmpty)
  }

  // ── Bitmap cues ──────────────────────────────────────

  private func pictureCue(_ relativeFrame: CGRect) throws -> UmbelSubtitleCue {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue))
    let image = try XCTUnwrap(context.makeImage())
    return UmbelSubtitleCue(
      start: .zero, end: nil, runs: [],
      image: UmbelSubtitleImage(image: image, relativeFrame: relativeFrame))
  }

  /// Placed by its fractions of the picture, the image itself untouched:
  /// scaling it is the compositor's job, done once on the GPU.
  func testBitmapCueIsPlacedByItsFractionsOfThePicture() throws {
    let cue = try pictureCue(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
    let drawn = render([cue])
    XCTAssertEqual(drawn.count, 1)
    XCTAssertEqual(drawn.first?.frame, CGRect(x: 320, y: 360, width: 640, height: 180))
    XCTAssertTrue(drawn.first?.image === cue.image?.image, "the decoded picture, not a copy")
  }

  func testBitmapAndTextCuesBothShow() throws {
    let drawn = render([try pictureCue(CGRect(x: 0, y: 0, width: 0.1, height: 0.1)), cue("text")])
    XCTAssertEqual(drawn.count, 2)
  }

  // ── Scale, and a picture larger than the canvas ─────

  func testAScaleOfTwoMakesTheTextAboutTwiceAsTall() throws {
    let plain = try XCTUnwrap(UmbelSubtitleRenderer().render([cue("Hg")], in: size).bitmaps.first)
    let scaled = try XCTUnwrap(
      UmbelSubtitleRenderer().render([cue("Hg")], in: size, scale: 2).bitmaps.first)
    XCTAssertGreaterThan(scaled.frame.height, plain.frame.height * 1.8)
  }

  /// Filling a 2:1 view, a square picture reaches past the canvas top and
  /// bottom. A bitmap keeps the picture's scale — not squashed to the
  /// canvas — and one past the bottom is moved up into it.
  func testABitmapFollowsThePictureAndIsMovedIntoTheCanvas() throws {
    let cue = try pictureCue(CGRect(x: 0.25, y: 0.9, width: 0.5, height: 0.08))
    let drawn = UmbelSubtitleRenderer().render(
      [cue], in: CGSize(width: 64, height: 32), picture: CGRect(x: 0, y: -16, width: 64, height: 64))
    let frame = try XCTUnwrap(drawn.bitmaps.first?.frame)
    XCTAssertEqual(frame.minX, 16, accuracy: 0.01)
    XCTAssertEqual(frame.width, 32, accuracy: 0.01)
    XCTAssertEqual(frame.height, 5.12, accuracy: 0.01)
    XCTAssertEqual(frame.maxY, 32, accuracy: 0.01, "moved up into what shows")
  }

  /// A bitmap in the lower half grows from its bottom edge, one in the upper
  /// half from its top edge: lines stay against the edge they were near.
  func testABitmapGrowsFromTheEdgeItIsNear() throws {
    let low = try pictureCue(CGRect(x: 0.25, y: 0.8, width: 0.5, height: 0.1))
    let high = try pictureCue(CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.1))
    let lowFrame = try XCTUnwrap(
      UmbelSubtitleRenderer().render([low], in: size, scale: 2).bitmaps.first?.frame)
    let highFrame = try XCTUnwrap(
      UmbelSubtitleRenderer().render([high], in: size, scale: 2).bitmaps.first?.frame)
    XCTAssertEqual(lowFrame, CGRect(x: 0, y: 504, width: 1280, height: 144))
    XCTAssertEqual(highFrame, CGRect(x: 0, y: 72, width: 1280, height: 144))
  }
}
