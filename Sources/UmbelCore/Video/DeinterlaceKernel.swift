import CoreVideo
import Foundation
import Metal

/// Which rows of an interlaced frame a picture keeps: the top field's (the
/// even rows, from 0) or the bottom field's (the odd rows).
internal enum VideoField: Sendable, Equatable {
  case top
  case bottom
}

/// Makes one progressive picture from an interlaced frame on the GPU, into a
/// new pixel buffer of the same kind; see `deinterlace.metalsrc` for how.
///
/// Waits for the GPU before returning: it runs where frames are decoded, off
/// the display path, and the picture must be whole before it is queued.
/// Used from one place at a time, as the decoding engine that owns it is.
internal final class DeinterlaceKernel: @unchecked Sendable {
  /// Below this much change between frames a pixel counts as still, above
  /// the other as moving; in between, the two results are mixed. Normalised
  /// code values, so 8 and 10 bits share them.
  static let stillBelow: Float = 6.0 / 255
  static let movingAbove: Float = 24.0 / 255

  private let queue: MTLCommandQueue
  private let state: MTLComputePipelineState
  private let textureCache: CVMetalTextureCache
  private var pool: (pool: CVPixelBufferPool, format: OSType, width: Int, height: Int)?

  init(device: MTLDevice) throws {
    guard let queue = device.makeCommandQueue() else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a command queue for deinterlacing")
    }
    self.queue = queue
    let library = try MetalPipeline.library(named: "deinterlace", device: device)
    guard let function = library.makeFunction(name: "umbelDeinterlace") else {
      throw UmbelError.videoRenderUnavailable(reason: "no deinterlacing function in its shader")
    }
    do {
      state = try device.makeComputePipelineState(function: function)
    } catch {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create the deinterlacing pipeline: \(error)")
    }
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
          let cache else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a texture cache for deinterlacing")
    }
    textureCache = cache
  }

  /// `field`'s rows kept, the others made; `previous`, the frame before,
  /// tells still from moving and is ignored unless of the same kind and size.
  /// `isFirst`: the kept field is the earlier of the two in time.
  func picture(
    from current: CVPixelBuffer, previous: CVPixelBuffer?, keeping field: VideoField, isFirst: Bool
  ) throws -> CVPixelBuffer {
    let formats = try Self.planeFormats(CVPixelBufferGetPixelFormatType(current))
    let output = try outputBuffer(like: current)
    let earlier = previous.flatMap { Self.matches($0, current) ? $0 : nil }
    guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot encode deinterlacing")
    }
    var retained: [CVMetalTexture] = []
    do {
      for (plane, format) in formats.enumerated() {
        let source = try texture(current, plane: plane, format: format, usage: .shaderRead, retained: &retained)
        let before = try earlier.map {
          try texture($0, plane: plane, format: format, usage: .shaderRead, retained: &retained)
        } ?? source
        let target = try texture(output, plane: plane, format: format, usage: .shaderWrite, retained: &retained)
        var parameters = DeinterlaceParameters(
          keptParity: field == .top ? 0 : 1, hasPrevious: earlier == nil ? 0 : 1,
          isFirstField: isFirst ? 1 : 0, stillBelow: Self.stillBelow, movingAbove: Self.movingAbove)
        encoder.setComputePipelineState(state)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(before, index: 1)
        encoder.setTexture(target, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<DeinterlaceParameters>.stride, index: 0)
        let side = 16
        encoder.dispatchThreadgroups(
          MTLSize(width: (target.width + side - 1) / side, height: (target.height + side - 1) / side, depth: 1),
          threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
      }
    } catch {
      encoder.endEncoding()
      throw error
    }
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime(retained) {}
    CVMetalTextureCacheFlush(textureCache, 0)
    guard command.status == .completed else {
      throw UmbelError.videoRenderUnavailable(reason: "deinterlacing did not complete")
    }
    return output
  }

  private static func planeFormats(_ format: OSType) throws -> [MTLPixelFormat] {
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
      return [.r8Unorm, .rg8Unorm]
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
      return [.r16Unorm, .rg16Unorm]
    default:
      throw UmbelError.videoRenderUnavailable(reason: "pixel format not supported for deinterlacing: \(format)")
    }
  }

  private static func matches(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
    CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b)
      && CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b)
      && CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b)
  }

  /// From a pool of buffers like `current`, made again when that changes;
  /// its colour attachments carried over.
  private func outputBuffer(like current: CVPixelBuffer) throws -> CVPixelBuffer {
    let format = CVPixelBufferGetPixelFormatType(current)
    let width = CVPixelBufferGetWidth(current), height = CVPixelBufferGetHeight(current)
    if pool?.format != format || pool?.width != width || pool?.height != height {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: format,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        kCVPixelBufferMetalCompatibilityKey: true,
      ]
      var made: CVPixelBufferPool?
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &made)
      guard let made else {
        throw UmbelError.videoRenderUnavailable(reason: "cannot create a buffer pool for deinterlacing")
      }
      pool = (made, format, width, height)
    }
    var buffer: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool.pool, &buffer) == kCVReturnSuccess,
          let buffer else {
      throw UmbelError.videoRenderUnavailable(reason: "no buffer to deinterlace into")
    }
    // Rewritten pixels invalidate opaque dynamic display metadata. Carry only
    // the public signal description; static HDR also remains on VideoFrame.
    for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                kCVImageBufferYCbCrMatrixKey, kCVImageBufferPixelAspectRatioKey] {
      if let value = CVBufferCopyAttachment(current, key, nil) {
        CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
      }
    }
    return buffer
  }

  private func texture(
    _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, usage: MTLTextureUsage,
    retained: inout [CVMetalTexture]
  ) throws -> MTLTexture {
    var made: CVMetalTexture?
    let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, textureCache, buffer, attributes, format,
      CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &made)
    guard status == kCVReturnSuccess, let made, let texture = CVMetalTextureGetTexture(made) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot make plane \(plane) a texture: \(status)")
    }
    retained.append(made)
    return texture
  }
}

/// As `DeinterlaceParameters` in the shader: three 32-bit integers, two floats.
private struct DeinterlaceParameters {
  var keptParity: UInt32
  var hasPrevious: UInt32
  var isFirstField: UInt32
  var stillBelow: Float
  var movingAbove: Float
}
