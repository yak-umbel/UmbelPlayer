import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// The picture's shape and scaling, drawn and read back as pixels: a square
/// grey picture in a 2:1 output.
final class PictureGeometryRenderingTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func renderer(output: CGSize) async throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let renderer = OffscreenVideoRenderer(
      pipeline: try MetalPipeline(device: device), outputSize: output, tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 64, color: VideoColorDescription(matrix: .bt709, range: .limited))
    return renderer
  }

  /// Grey: luma 126 in limited range, about 128 out.
  private func show(_ renderer: OffscreenVideoRenderer) async throws {
    let buffer = VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: 126, cb: 128, cr: 128)!
    try await renderer.enqueue(VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .limited)))
    _ = try await renderer.presentFrame(at: .zero)
  }

  private func level(_ renderer: OffscreenVideoRenderer, x: Int, y: Int) async throws -> Int {
    Int(try await renderer.readPixel(x: x, y: y).g)
  }

  private func white() throws -> CGImage {
    let bytes = [UInt8](repeating: 255, count: 4 * 4 * 2)
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    return try XCTUnwrap(CGImage(
      width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  }

  func testFitLeavesBarsAtTheSides() async throws {
    let renderer = try await renderer(output: CGSize(width: 64, height: 32))
    try await show(renderer)
    let bar = try await level(renderer, x: 4, y: 16)
    XCTAssertLessThan(bar, 8, "black bar beside a square picture in a wide output")
  }

  func testFillCoversTheOutput() async throws {
    let renderer = try await renderer(output: CGSize(width: 64, height: 32))
    await renderer.setPictureGeometry(aspectRatio: nil, scaling: .fill)
    try await show(renderer)
    let edge = try await level(renderer, x: 4, y: 16)
    XCTAssertEqual(edge, 128, accuracy: 3, "picture to the edge")
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 64, height: 32), "subtitles laid out on what shows")
    let frame = await renderer.subtitlePictureFrame
    XCTAssertEqual(frame, CGRect(x: 0, y: -16, width: 64, height: 64))
  }

  /// A block at the canvas's bottom shows whole: the canvas is what shows.
  func testASubtitleAtTheBottomShowsWhenFilling() async throws {
    let renderer = try await renderer(output: CGSize(width: 64, height: 32))
    await renderer.setPictureGeometry(aspectRatio: nil, scaling: .fill)
    await renderer.setSubtitles([
      UmbelSubtitleBitmap(image: try white(), frame: CGRect(x: 16, y: 24, width: 32, height: 8)),
    ])
    try await show(renderer)
    let line = try await level(renderer, x: 32, y: 28)
    XCTAssertGreaterThan(line, 250)
  }

  func testAnAspectRatioStretchesThePicture() async throws {
    let renderer = try await renderer(output: CGSize(width: 64, height: 32))
    await renderer.setPictureGeometry(aspectRatio: 2, scaling: .fit)
    try await show(renderer)
    let edge = try await level(renderer, x: 2, y: 16)
    XCTAssertEqual(edge, 128, accuracy: 3, "a 2:1 picture fills a 2:1 output")
  }

  /// Fitted, the subtitle canvas is the picture, as it always was.
  func testFittedTheCanvasIsThePicture() async throws {
    let renderer = try await renderer(output: CGSize(width: 64, height: 32))
    try await show(renderer)
    let canvas = await renderer.subtitleCanvasSize
    let frame = await renderer.subtitlePictureFrame
    XCTAssertEqual(canvas, CGSize(width: 32, height: 32))
    XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 32, height: 32))
  }
}
