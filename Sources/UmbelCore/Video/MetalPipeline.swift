import CoreVideo
import Foundation
import Metal

/// Shaders and the texture cache, shared by both renderers.
///
/// Textures are kept alive by a small object with its own lock rather than
/// a mutable property here: rendering on screen releases them in the command
/// buffer's completion handler, which cannot capture an actor's self.
internal final class MetalPipeline: @unchecked Sendable {
  internal let device: MTLDevice
  internal let commandQueue: MTLCommandQueue
  /// Draws the picture, one state per supported target precision.
  private let videoStates: [MTLPixelFormat: MTLRenderPipelineState]
  /// Draws subtitle images over the picture, likewise.
  private let overlayStates: [MTLPixelFormat: MTLRenderPipelineState]
  private let exportState: MTLRenderPipelineState
  private let textureCache: CVMetalTextureCache
  private let retained = RetainedTextures()

  internal static func makeDevice() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw UmbelError.videoRenderUnavailable(reason: "no graphics device")
    }
    return device
  }

  internal init(device: MTLDevice) throws {
    self.device = device

    guard let queue = device.makeCommandQueue() else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a command queue")
    }
    self.commandQueue = queue

    let library = try Self.library(named: "video", device: device)
    let overlayLibrary = try Self.library(named: "subtitle_overlay", device: device)
    var videoStates: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    var overlayStates: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    do {
      for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float, .rgba32Float] {
        do {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "umbelVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "umbelFragment")
        descriptor.colorAttachments[0].pixelFormat = format
        videoStates[format] = try device.makeRenderPipelineState(descriptor: descriptor)
        overlayStates[format] = try SubtitleOverlay.makePipelineState(
          device: device, library: overlayLibrary, format: format)
        } catch {
          if format != .rgba32Float { throw error }
          videoStates.removeValue(forKey: format)
        }
      }
      self.videoStates = videoStates
      self.overlayStates = overlayStates
      let export = MTLRenderPipelineDescriptor()
      export.vertexFunction = library.makeFunction(name: "umbelVertex")
      export.fragmentFunction = library.makeFunction(name: "umbelExport")
      export.colorAttachments[0].pixelFormat = .bgra8Unorm
      exportState = try device.makeRenderPipelineState(descriptor: export)
    } catch {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create the render pipeline: \(error)")
    }

    var cache: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    guard status == kCVReturnSuccess, let cache else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create the texture cache: \(status)")
    }
    self.textureCache = cache
  }

  func supports(_ format: MTLPixelFormat) -> Bool {
    videoStates[format] != nil && overlayStates[format] != nil
  }

  /// Convert the complete composition into sRGB only at the export boundary.
  func encodeExport(_ texture: MTLTexture, encoding: Int32, into encoder: MTLRenderCommandEncoder) {
    encoder.setRenderPipelineState(exportState)
    encoder.setViewport(.init(originX: 0, originY: 0, width: Double(texture.width),
      height: Double(texture.height), znear: 0, zfar: 1))
    var turns: UInt32 = 0
    var encoding = encoding
    encoder.setVertexBytes(&turns, length: MemoryLayout<UInt32>.stride, index: 0)
    encoder.setFragmentTexture(texture, index: 0)
    encoder.setFragmentBytes(&encoding, length: MemoryLayout<Int32>.stride, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
  }

  /// Turns a biplanar buffer into two textures, **with no copy through the
  /// CPU** — the step that makes the path copy-free.
  ///
  /// Planes map to formats as the system headers describe: luma one channel
  /// at full size, chroma two channels at half size.
  ///
  /// 8-bit frames (NV12) map to 8-bit textures, 10-bit ones (P010) to 16-bit
  /// textures. P010 keeps its ten bits at the top of each sixteen, so the
  /// normalised values match the 8-bit ones and the shader needs no change.
  /// Anything else is refused rather than drawn as noise.
  internal func makeTextures(
    from pixelBuffer: CVPixelBuffer
  ) throws -> (luma: MTLTexture, chroma: MTLTexture) {
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let rgb: MTLPixelFormat?
    switch pixelFormat {
    case kCVPixelFormatType_32BGRA: rgb = .bgra8Unorm
    case kCVPixelFormatType_64RGBALE: rgb = .rgba16Unorm
    case kCVPixelFormatType_64RGBAHalf: rgb = .rgba16Float
    case kCVPixelFormatType_128RGBAFloat: rgb = .rgba32Float
    default: rgb = nil
    }
    if let rgb {
      let texture = try makeTexture(from: pixelBuffer, plane: 0, format: rgb,
        width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
      return (texture, texture)
    }
    let formats: (luma: MTLPixelFormat, chroma: MTLPixelFormat)
    switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
      formats = (.r8Unorm, .rg8Unorm)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
      formats = (.r16Unorm, .rg16Unorm)
    case let other:
      throw UmbelError.videoRenderUnavailable(reason: "pixel format not supported: \(other)")
    }

    let luma = try makeTexture(
      from: pixelBuffer, plane: 0, format: formats.luma,
      width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
      height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
    let chroma = try makeTexture(
      from: pixelBuffer, plane: 1, format: formats.chroma,
      width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
      height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
    return (luma, chroma)
  }

  /// A texture to draw into a BGRA buffer, **with no copy**: what is drawn
  /// lands in the buffer. For the sample buffer renderer, whose pictures go
  /// to the system as buffers.
  internal func makeTargetTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
    try makeTexture(
      from: pixelBuffer, plane: 0,
      format: CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf ? .rgba16Float : .bgra8Unorm,
      width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
      usage: [.shaderRead, .renderTarget])
  }

  /// Encodes one picture: the frame, then the subtitles over it. Both
  /// renderers draw through here; only their targets differ.
  ///
  /// `layout.picture` is where the frame goes in the target, in pixels from
  /// the top-left; outside it the target keeps its clear colour. Subtitles
  /// go in `layout.visible`, the part of the picture inside the target, so
  /// none is cut off with the picture's edges.
  ///
  /// Each frame is drawn by its own colour description: a film can switch
  /// range or matrix, and the one given when preparing is only a guess.
  /// `output` is what the target holds, and must match its format.
  internal func encode(
    _ frame: VideoFrame, output: VideoOutput, subtitles: SubtitleOverlay,
    layout: PictureLayout, adjustments: UmbelVideoAdjustments = .init(),
    into encoder: MTLRenderCommandEncoder
  ) throws {
    let picture = layout.picture
    guard let videoState = videoStates[output.pixelFormat],
          let overlayState = overlayStates[output.pixelFormat] else {
      throw UmbelError.videoRenderUnavailable(reason: "no render pipeline for \(output)")
    }
    guard let pixelBuffer = frame.pixelBuffer else {
      throw UmbelError.videoRenderUnavailable(reason: "a picture only the system can show")
    }
    let textures = try makeTextures(from: pixelBuffer)
    encoder.setViewport(
      MTLViewport(
        originX: picture.minX, originY: picture.minY,
        width: picture.width, height: picture.height, znear: 0, zfar: 1))
    var uniforms = ColorUniforms(
      for: frame.color,
      matrix: frame.color.matrix(forWidth: frame.width, height: frame.height),
      bitDepth: frame.effectiveBitDepth ?? 8)
    // HDR into a standard-range target: tone-mapped on the way. Into an HDR
    // target: decoded to linear light, so what is drawn over it blends as
    // light does.
    if output.isStandard {
      uniforms.setToneMapping(for: frame.color)
      if output.isLinearStandard { uniforms.linearOutput = 3 }
      else if output.encoding == .standardSRGB { uniforms.linearOutput = 4 }
    } else {
      switch frame.color.transfer {
      case .pq: uniforms.linearOutput = 1
      case .hlg: uniforms.linearOutput = 2
      case .sdr: uniforms.linearOutput = 0
      }
    }
    uniforms.sourceTransfer = frame.color.transferCode
    uniforms.inputRGB = frame.pixelDescription?.isRGB == true ? 1 : 0
    let sampling = frame.pixelDescription?.chromaSubsampling
    let factors = SIMD2<Float>(sampling == "4:2:0" || sampling == "4:2:2" ? 2 : 1, sampling == "4:2:0" ? 2 : 1)
    let location = frame.chromaLocationCode
    let siting = SIMD2<Float>(factors.x == 1 ? 0 : [1, 3, 5].contains(location) ? 0 : 0.5,
      factors.y == 1 ? 0 : [3, 4].contains(location) ? 0 : [5, 6].contains(location) ? 1 : 0.5)
    let chromaSize = SIMD2<Float>(Float(textures.chroma.width), Float(textures.chroma.height))
    let lumaSize = SIMD2<Float>(Float(textures.luma.width), Float(textures.luma.height))
    uniforms.chromaScaleUV = lumaSize / (factors * chromaSize)
    uniforms.chromaOffsetUV = (SIMD2<Float>(repeating: 0.5) - (siting + 0.5) / factors) / chromaSize
    uniforms.setGamut(for: frame.color, output: output)
    uniforms.ditherOutput = output.pixelFormat == .bgra8Unorm &&
      ((frame.effectiveBitDepth ?? 0) > 8 || (frame.sourcePixelDescription?.effectiveBits ?? 0) > 8 || frame.color.isHDR) ? 1 : 0
    uniforms.setAdjustments(adjustments, output: output)
    encoder.setRenderPipelineState(videoState)
    encoder.setFragmentTexture(textures.luma, index: 0)
    encoder.setFragmentTexture(textures.chroma, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ColorUniforms>.stride, index: 0)
    // The picture's clockwise quarter turns, for the vertex stage.
    var turns = UInt32(frame.rotation.rawValue / 90)
    encoder.setVertexBytes(&turns, length: MemoryLayout<UInt32>.stride, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encodeOverlay(subtitles, state: overlayState, in: layout.visible, output: output, into: encoder)
  }

  /// Subtitles alone, framed in `layout.visible` as `encode` frames them,
  /// over whatever the target was cleared to: for a picture the system shows
  /// beneath (DV profile 5), the target cleared to nothing.
  internal func encodeSubtitles(
    _ subtitles: SubtitleOverlay, output: VideoOutput, layout: PictureLayout,
    into encoder: MTLRenderCommandEncoder
  ) throws {
    guard let overlayState = overlayStates[output.pixelFormat] else {
      throw UmbelError.videoRenderUnavailable(reason: "no render pipeline for \(output)")
    }
    encodeOverlay(subtitles, state: overlayState, in: layout.visible, output: output, into: encoder)
  }

  /// The subtitles, their canvas the `area` given, its own viewport.
  private func encodeOverlay(
    _ subtitles: SubtitleOverlay, state: MTLRenderPipelineState, in area: CGRect,
    output: VideoOutput, into encoder: MTLRenderCommandEncoder
  ) {
    guard area.width > 0, area.height > 0 else { return }
    encoder.setViewport(
      MTLViewport(
        originX: area.minX, originY: area.minY,
        width: area.width, height: area.height, znear: 0, zfar: 1))
    subtitles.encode(into: encoder, state: state, canvas: area.size, output: output)
  }

  /// Called once the command buffer has run; safe from any thread. Rendering
  /// on screen calls it from the completion handler, which cannot capture an
  /// actor.
  internal func releaseRetainedTextures() {
    retained.removeAll()
  }

  /// Shader source ships as a resource and is compiled at start-up; see the
  /// package manifest for why it is not named .metal.
  internal static func library(named name: String, device: MTLDevice) throws -> MTLLibrary {
    guard let url = Bundle.module.url(forResource: name, withExtension: "metalsrc") else {
      throw UmbelError.videoRenderUnavailable(reason: "no shader source \(name) in the resources")
    }
    do {
      let source = try String(contentsOf: url, encoding: .utf8)
      return try device.makeLibrary(source: source, options: nil)
    } catch {
      throw UmbelError.videoRenderUnavailable(reason: "shader \(name) failed to compile: \(error)")
    }
  }

  private func makeTexture(
    from pixelBuffer: CVPixelBuffer,
    plane: Int,
    format: MTLPixelFormat,
    width: Int,
    height: Int,
    usage: MTLTextureUsage = .shaderRead
  ) throws -> MTLTexture {
    var textureRef: CVMetalTexture?
    let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, pixelBuffer, attributes,
      format, width, height, plane, &textureRef)
    guard status == kCVReturnSuccess,
          let textureRef,
          let texture = CVMetalTextureGetTexture(textureRef) else {
      throw UmbelError.videoRenderUnavailable(
        reason: "cannot make plane \(plane) a texture: \(status)")
    }
    retained.append(textureRef)
    return texture
  }
}

/// Textures have to live until the command buffer has run, or they are
/// reclaimed beneath it too early.
///
/// A class with a lock rather than an actor: they are released in the
/// command buffer's completion handler, a synchronous context that cannot
/// await, and which cannot capture an actor's self either.
private final class RetainedTextures: @unchecked Sendable {
  private let lock = NSLock()
  private var textures: [CVMetalTexture] = []

  func append(_ texture: CVMetalTexture) {
    lock.lock()
    defer { lock.unlock() }
    textures.append(texture)
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    textures.removeAll()
  }
}
