import CoreGraphics
import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import UmbelCore

/// Subtitles drawn into the picture by the renderer, read back as pixels.
final class SubtitleCompositingTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func pipeline() throws -> MetalPipeline {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return try MetalPipeline(device: device)
  }

  /// A 64×64 renderer. Grey is luma 126 in limited range: about 128 out.
  private func renderer() async throws -> OffscreenVideoRenderer {
    let renderer = OffscreenVideoRenderer(pipeline: try pipeline(), tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 64, color: VideoColorDescription(matrix: .bt709, range: .limited))
    return renderer
  }

  private func frame(luma: UInt8, seconds: Double = 0) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: luma, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      pixelBuffer: buffer, width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  /// A solid image of one premultiplied grey level and alpha.
  private func solid(level: UInt8, alpha: UInt8, width: Int = 4, height: Int = 2) throws -> CGImage {
    var bytes = [UInt8]()
    for _ in 0..<width * height { bytes += [level, level, level, alpha] }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    return try XCTUnwrap(
      CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  }

  /// A white block over the lower middle; the image is 4×2 and scaled up
  /// to its frame, as bitmap subtitles are.
  private func whiteBlock() throws -> UmbelSubtitleBitmap {
    UmbelSubtitleBitmap(
      image: try solid(level: 255, alpha: 255), frame: CGRect(x: 16, y: 40, width: 32, height: 16))
  }

  private func level(_ renderer: OffscreenVideoRenderer, x: Int, y: Int) async throws -> Int {
    Int(try await renderer.readPixel(x: x, y: y).g)
  }

  func testCanvasIsThePictureInPixels() async throws {
    let renderer = try await renderer()
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 64, height: 64))
  }

  func testSubtitleIsDrawnOverThePictureWhereItsFrameSays() async throws {
    let renderer = try await renderer()
    await renderer.setSubtitles([try whiteBlock()])
    try await renderer.enqueue(frame(luma: 126))
    _ = try await renderer.presentFrame(at: .zero)

    let inside = try await level(renderer, x: 32, y: 48)
    let above = try await level(renderer, x: 32, y: 36)
    let left = try await level(renderer, x: 12, y: 48)
    XCTAssertGreaterThan(inside, 250, "white where the subtitle is")
    XCTAssertEqual(above, 128, accuracy: 3, "grey picture above it — not upside down")
    XCTAssertEqual(left, 128, accuracy: 3, "grey picture beside it")
  }

  /// Premultiplied: white at half coverage is stored as 128, and over black
  /// it must come out as 128. Blended as straight alpha it would be halved
  /// again, to 64.
  func testBlendingIsPremultiplied() async throws {
    let renderer = try await renderer()
    await renderer.setSubtitles([
      UmbelSubtitleBitmap(
        image: try solid(level: 128, alpha: 128), frame: CGRect(x: 0, y: 0, width: 64, height: 64)),
    ])
    try await renderer.enqueue(frame(luma: 16))
    _ = try await renderer.presentFrame(at: .zero)
    let blended = try await level(renderer, x: 32, y: 32)
    XCTAssertEqual(blended, 128, accuracy: 4)
  }

  /// Paused, no new frame is due, and yet a line appearing has to show: the
  /// renderer draws the last frame again.
  func testChangingSubtitlesRedrawsWithoutANewFrame() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(frame(luma: 126))
    _ = try await renderer.presentFrame(at: .zero)
    let before = try await level(renderer, x: 32, y: 48)
    XCTAssertEqual(before, 128, accuracy: 3)

    await renderer.setSubtitles([try whiteBlock()])
    let presented = try await renderer.presentFrame(at: .zero)
    XCTAssertNil(presented, "no new video frame")
    let shown = try await level(renderer, x: 32, y: 48)
    XCTAssertGreaterThan(shown, 250, "drawn again, with the line")

    await renderer.setSubtitles([])
    _ = try await renderer.presentFrame(at: .zero)
    let cleared = try await level(renderer, x: 32, y: 48)
    XCTAssertEqual(cleared, 128, accuracy: 3, "and again without it")
  }

  /// After a seek the old picture must not come back for a subtitle change.
  func testFlushForgetsTheLastFrame() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(frame(luma: 126))
    _ = try await renderer.presentFrame(at: .zero)
    await renderer.flush()
    await renderer.setSubtitles([try whiteBlock()])
    _ = try await renderer.presentFrame(at: .zero)
    let untouched = try await level(renderer, x: 32, y: 48)
    XCTAssertEqual(untouched, 128, accuracy: 3, "nothing redrawn from before the seek")
  }

  /// The on-screen renderer does the same; without a window it has no
  /// drawable, and that must not be an error.
  func testOnScreenRendererAcceptsSubtitles() async throws {
    let layer = CAMetalLayer()
    let renderer = MetalVideoRenderer(pipeline: try pipeline(), layer: layer, tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 48, color: VideoColorDescription(matrix: .bt709, range: .limited))
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 64, height: 48))
    try await renderer.enqueue(frame(luma: 126))
    _ = try await renderer.presentFrame(at: .zero)
    await renderer.setSubtitles([try whiteBlock()])
    _ = try await renderer.presentFrame(at: .zero)
  }

  // ── Drawn at the output's resolution ─────────────────

  /// A 64×64 video in a 256×128 output: the picture is 128×128 in the
  /// middle, black bars either side, and subtitles are laid out for the
  /// picture at that size — twice the video's — so text stays sharp.
  func testPictureIsFittedAndSubtitlesDrawnAtTheOutputsResolution() async throws {
    let renderer = OffscreenVideoRenderer(
      pipeline: try pipeline(), outputSize: CGSize(width: 256, height: 128), tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 64, color: VideoColorDescription(matrix: .bt709, range: .limited))
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 128, height: 128))

    await renderer.setSubtitles([
      UmbelSubtitleBitmap(
        image: try solid(level: 255, alpha: 255), frame: CGRect(x: 32, y: 80, width: 64, height: 32)),
    ])
    try await renderer.enqueue(frame(luma: 126))
    _ = try await renderer.presentFrame(at: .zero)

    let bar = try await level(renderer, x: 20, y: 64)
    let picture = try await level(renderer, x: 128, y: 20)
    let subtitle = try await level(renderer, x: 128, y: 96)
    let besideSubtitle = try await level(renderer, x: 90, y: 96)
    XCTAssertEqual(bar, 0, "black bar")
    XCTAssertEqual(picture, 128, accuracy: 3)
    XCTAssertGreaterThan(subtitle, 250, "the subtitle, placed within the picture")
    XCTAssertEqual(besideSubtitle, 128, accuracy: 3)
  }

  /// On screen the host sizes the drawable to its view; the picture is
  /// fitted into it and the subtitle canvas follows.
  func testOnScreenCanvasFollowsTheDrawableTheHostSized() async throws {
    let layer = CAMetalLayer()
    layer.drawableSize = CGSize(width: 200, height: 100)
    let renderer = MetalVideoRenderer(pipeline: try pipeline(), layer: layer, tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 48, color: VideoColorDescription(matrix: .bt709, range: .limited))
    let canvas = await renderer.subtitleCanvasSize
    // Had preparing reset the drawable to the video's size, this would be 64×48.
    XCTAssertEqual(canvas, CGSize(width: 133, height: 100))
  }
}
