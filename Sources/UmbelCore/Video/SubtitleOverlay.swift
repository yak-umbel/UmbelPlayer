import CoreGraphics
import Foundation
import Metal

/// Subtitle images drawn over the picture, in the render pass that drew it.
///
/// Each renderer keeps one. Textures are made when the subtitles change and
/// kept until they change again: a line that shows for three seconds is
/// uploaded once, not every frame. Command buffers retain the textures they
/// use, so replacing them while the GPU is still drawing is safe.
internal struct SubtitleOverlay {
  private var placed: [(texture: MTLTexture, frame: CGRect)] = []

  /// Replaces what is drawn. An image that cannot become a texture is left
  /// out: a missing line beats a missing picture.
  mutating func update(_ bitmaps: [UmbelSubtitleBitmap], device: MTLDevice) {
    placed = bitmaps.compactMap { bitmap in
      Self.texture(from: bitmap.image, device: device).map { ($0, bitmap.frame) }
    }
  }

  /// Draws every image, each scaled to its frame. `canvas` is the render
  /// target's size in pixels, the space the frames are in.
  ///
  /// Over HDR the images are converted to the target's encoding with their
  /// white at BT.2408's reference white — 203 nits for PQ, 75% for HLG —
  /// as bright as the interface around the picture rather than its peak.
  func encode(
    into encoder: MTLRenderCommandEncoder, state: MTLRenderPipelineState, canvas: CGSize,
    output: VideoOutput
  ) {
    guard !placed.isEmpty, canvas.width > 0, canvas.height > 0 else { return }
    encoder.setRenderPipelineState(state)
    var target = output.shaderCode
    encoder.setFragmentBytes(&target, length: MemoryLayout<Int32>.stride, index: 0)
    for (texture, frame) in placed {
      // Pixels from the top-left to clip space: x right, y up, both -1...1.
      var corners = SIMD4<Float>(
        Float(frame.minX / canvas.width * 2 - 1), Float(1 - frame.minY / canvas.height * 2),
        Float(frame.maxX / canvas.width * 2 - 1), Float(1 - frame.maxY / canvas.height * 2))
      encoder.setVertexBytes(&corners, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
  }

  /// Blends premultiplied colour: source + destination × (1 − source alpha).
  static func makePipelineState(
    device: MTLDevice, library: MTLLibrary, format: MTLPixelFormat
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "subtitleVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "subtitleFragment")
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = format
    attachment.isBlendingEnabled = true
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  /// Drawn through a bitmap context so any image comes out as premultiplied
  /// BGRA, the texture's format; for the images subtitles produce that is
  /// already their layout.
  private static func texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    texture.replace(
      region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
      withBytes: pixels, bytesPerRow: width * 4)
    return texture
  }
}
