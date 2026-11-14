import CoreGraphics
import Metal
import XCTest
@testable import UmbelCore

/// Subtitles alone, over a layer cleared to nothing: what the window draws
/// over a picture the system shows (DV profile 5).
final class SubtitleOverlayOnlyTests: XCTestCase {
  private func pipeline() throws -> MetalPipeline {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return try MetalPipeline(device: device)
  }

  /// A white block, its frame in the picture's pixels.
  private func whiteBlock(_ frame: CGRect) throws -> UmbelSubtitleBitmap {
    var bytes = [UInt8]()
    for _ in 0..<8 { bytes += [255, 255, 255, 255] }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return UmbelSubtitleBitmap(image: image, frame: frame)
  }

  /// Draws the subtitles into a cleared BGRA target of `size`, the picture
  /// fitted into it; returns the target's bytes, four to a pixel.
  private func drawn(
    _ bitmaps: [UmbelSubtitleBitmap], picture: CGSize, target size: CGSize
  ) throws -> (bytes: [UInt8], width: Int) {
    let pipeline = try pipeline()
    let width = Int(size.width), height = Int(size.height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let target = try XCTUnwrap(pipeline.device.makeTexture(descriptor: descriptor))
    var overlay = SubtitleOverlay()
    overlay.update(bitmaps, device: pipeline.device)

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    let commands = try XCTUnwrap(pipeline.commandQueue.makeCommandBuffer())
    let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
    try pipeline.encodeSubtitles(
      overlay, output: .standard,
      layout: PictureFit.layout(picture: picture, in: size, geometry: .standard), into: encoder)
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(
      &bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return (bytes, width)
  }

  private func alpha(_ drawn: (bytes: [UInt8], width: Int), x: Int, y: Int) -> UInt8 {
    drawn.bytes[(y * drawn.width + x) * 4 + 3]
  }

  func testOnlyTheSubtitlesAreDrawnTheRestStaysClear() throws {
    let result = try drawn(
      [try whiteBlock(CGRect(x: 16, y: 40, width: 32, height: 16))],
      picture: CGSize(width: 64, height: 64), target: CGSize(width: 64, height: 64))
    XCTAssertEqual(alpha(result, x: 32, y: 48), 255, "the subtitle")
    XCTAssertEqual(alpha(result, x: 32, y: 10), 0, "the picture's place: clear, for the system's picture beneath")
    XCTAssertEqual(alpha(result, x: 2, y: 2), 0)
  }

  /// A square picture in a wide layer sits in the middle; its subtitles sit on it.
  func testTheSubtitlesSitOnThePictureAsTheLayerFitsIt() throws {
    let result = try drawn(
      [try whiteBlock(CGRect(x: 16, y: 40, width: 32, height: 16))],
      picture: CGSize(width: 64, height: 64), target: CGSize(width: 128, height: 64))
    XCTAssertEqual(alpha(result, x: 64, y: 48), 255, "32 in from the picture, which starts 32 in")
    XCTAssertEqual(alpha(result, x: 24, y: 48), 0, "in the left bar: nothing")
  }
}
