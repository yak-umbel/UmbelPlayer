import CoreVideo
import FFmpeg
import Foundation

/// Owns software pixel conversion, its buffer pool and the cached scaler.
internal final class VideoPixelBufferConverter {
  private var pixelBufferPool: CVPixelBufferPool?
  /// Actual system representation, including deep YUV and packed RGB.
  private var poolFormat: OSType = 0
  private var poolWidth = 0
  private var poolHeight = 0
  private struct BufferAllocationKey: Hashable { let format: OSType; let width: Int32; let height: Int32 }
  private var unavailableBufferFormats: Set<BufferAllocationKey> = []
  private var conversionReason: String?
  /// Converts software frames that are not plain 8-bit 4:2:0.
  private var scaler: UnsafeMutablePointer<SwsContext>?

  deinit { sws_freeContext(scaler) }

  func reset() {
    pixelBufferPool = nil
    sws_freeContext(scaler)
    scaler = nil
    unavailableBufferFormats.removeAll()
    conversionReason = nil
  }

  func convert(_ frame: UnsafeMutablePointer<AVFrame>, width: Int32, height: Int32,
               codecName: String) throws -> (buffer: CVPixelBuffer, reason: String?) {
    let buffer = try copyIntoPixelBuffer(frame, width: width, height: height, codecName: codecName)
    return (buffer, conversionReason)
  }

  /// Preserve planar precision and chroma sampling where system buffers
  /// support them. Packed RGB remains RGB; compatible 4:2:0 is a fallback.
  private func copyIntoPixelBuffer(
    _ frame: UnsafeMutablePointer<AVFrame>,
    width: Int32,
    height: Int32, codecName: String
  ) throws -> CVPixelBuffer {
    let source = AVPixelFormat(rawValue: frame.pointee.format)
    // The format's own sample depth: 10 for HEVC Main 10. The decoder's
    // bits_per_raw_sample would be simpler, but HEVC leaves it at zero.
    conversionReason = nil
    guard let sourceFormat = FFmpegVideoFormat(pixelFormatCode: source.rawValue),
          let depth = sourceFormat.componentDepths.max(), depth > 0 else {
      throw FFmpegDecoderError.unsupportedPixelFormat(source.rawValue)
    }
    let rgb = sourceFormat.isRGB
    let floatRGB = rgb && sourceFormat.isFloatingPoint
    var planarTarget = PlanarVideoCopy.target(for: frame)
    let full = frame.pointee.color_range == AVCOL_RANGE_JPEG || source == AV_PIX_FMT_YUVJ420P
    let compatibleTarget = depth > 8
      ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
      : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    var target = rgb ? (floatRGB ? kCVPixelFormatType_128RGBAFloat : depth > 8 ? kCVPixelFormatType_64RGBALE : kCVPixelFormatType_32BGRA)
      : planarTarget ?? (depth > 8
      ? (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
      : (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    let allocationKey = BufferAllocationKey(format: target, width: width, height: height)
    if unavailableBufferFormats.contains(allocationKey) {
      target = compatibleTarget; planarTarget = nil; conversionReason = "resourceAllocationFailed"
    }
    if pixelBufferPool == nil || poolFormat != target || poolWidth != Int(width) || poolHeight != Int(height) {
      do { try makePool(width: Int(width), height: Int(height), format: target) }
      catch {
        guard target != compatibleTarget else { throw error }
        unavailableBufferFormats.insert(allocationKey)
        target = compatibleTarget; planarTarget = nil; conversionReason = "resourceAllocationFailed"
        try makePool(width: Int(width), height: Int(height), format: target)
      }
    }
    guard let pool = pixelBufferPool else {
      throw FFmpegDecoderError.contextAllocationFailed
    }

    var created: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
            == kCVReturnSuccess,
          let buffer = created else {
      throw FFmpegDecoderError.contextAllocationFailed
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if planarTarget != nil {
      try PlanarVideoCopy.write(frame, into: buffer, interlaced: FFmpegVideoDecoder.reportsInterlaced(
        flagged: frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0, codecName: codecName))
      return buffer
    }

    let isPlainEightBit = !rgb && (source == AV_PIX_FMT_YUV420P || source == AV_PIX_FMT_YUVJ420P)
    guard isPlainEightBit else {
      try scale(frame, from: source, into: buffer, width: width, height: height,
                as: Self.isRGBBuffer(buffer) ? (floatRGB ? AV_PIX_FMT_RGBAF32LE : depth > 8 ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_BGRA)
                  : depth > 8 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12,
                byField: FieldwiseScaling.applies(to: frame, source: source, height: height, codecName: codecName))
      return buffer
    }

    // Luma, row by row: source and destination rows usually differ in stride.
    if let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
       let source = frame.pointee.data.0 {
      let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      let sourceStride = Int(frame.pointee.linesize.0)
      let rows = Int(height)
      for row in 0..<rows {
        memcpy(destination + row * destinationStride,
               source + row * sourceStride,
               min(destinationStride, sourceStride))
      }
    }

    // Chroma: two separate planes in the source, one interleaved plane in the
    // destination.
    if let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
       let sourceCb = frame.pointee.data.1,
       let sourceCr = frame.pointee.data.2 {
      let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
      let cbStride = Int(frame.pointee.linesize.1)
      let crStride = Int(frame.pointee.linesize.2)
      let rows = (Int(height) + 1) / 2
      let columns = (Int(width) + 1) / 2
      let target = destination.assumingMemoryBound(to: UInt8.self)
      for row in 0..<rows {
        let line = target + row * destinationStride
        let cbLine = sourceCb + row * cbStride
        let crLine = sourceCr + row * crStride
        for column in 0..<columns {
          line[column * 2] = cbLine[column]
          line[column * 2 + 1] = crLine[column]
        }
      }
    }
    return buffer
  }

  private func scale(
    _ frame: UnsafeMutablePointer<AVFrame>,
    from source: AVPixelFormat,
    into buffer: CVPixelBuffer,
    width: Int32,
    height: Int32,
    as target: AVPixelFormat,
    byField: Bool
  ) throws {
    let passes = FieldwiseScaling.passes(of: frame, into: buffer, height: height, byField: byField)
    guard let rows = passes.first?.rows else { return }
    scaler = sws_getCachedContext(
      scaler, width, rows, source, width, rows, target, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
    guard let scaler else { throw FFmpegDecoderError.unsupportedPixelFormat(source.rawValue) }
    let matrix: Int32
    switch frame.pointee.colorspace {
    case AVCOL_SPC_BT709: matrix = SWS_CS_ITU709
    case AVCOL_SPC_BT2020_NCL: matrix = SWS_CS_BT2020
    case AVCOL_SPC_RGB: matrix = SWS_CS_ITU709
    case AVCOL_SPC_UNSPECIFIED:
      matrix = width >= 1280 || height > 576 ? SWS_CS_ITU709 : SWS_CS_ITU601
    default: matrix = SWS_CS_ITU601
    }
    let sourceRGB = FFmpegVideoFormat(pixelFormatCode: source.rawValue)?.isRGB == true
    let coefficients = sws_getCoefficients(sourceRGB ? SWS_CS_ITU709 : matrix)
    let sourceFull: Int32 = sourceRGB || frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
    let targetFull: Int32 = Self.isRGBBuffer(buffer) ||
      [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
        .contains(CVPixelBufferGetPixelFormatType(buffer)) ? 1 : 0
    guard sws_setColorspaceDetails(scaler, coefficients, sourceFull, coefficients, targetFull, 0, 1 << 16, 1 << 16) >= 0 else {
      throw FFmpegDecoderError.unsupportedPixelFormat(source.rawValue)
    }
    for pass in passes {
      let done = sws_scale(
        scaler, pass.sources, pass.sourceStrides, 0, pass.rows, pass.destinations, pass.destinationStrides)
      guard done == pass.rows else { throw FFmpegDecoderError.unsupportedPixelFormat(source.rawValue) }
    }
  }

  private func makePool(width: Int, height: Int, format: OSType) throws {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: Int(format),
      kCVPixelBufferWidthKey: width,
      kCVPixelBufferHeightKey: height,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var pool: CVPixelBufferPool?
    guard CVPixelBufferPoolCreate(
      kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
      throw FFmpegDecoderError.contextAllocationFailed
    }
    pixelBufferPool = pool
    poolFormat = format
    poolWidth = width
    poolHeight = height
  }

  static func isRGBBuffer(_ buffer: CVPixelBuffer) -> Bool {
    [kCVPixelFormatType_32BGRA, kCVPixelFormatType_64RGBALE, kCVPixelFormatType_128RGBAFloat]
      .contains(CVPixelBufferGetPixelFormatType(buffer))
  }

  static func isFullRangeBuffer(_ buffer: CVPixelBuffer) -> Bool {
    isRGBBuffer(buffer) || [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
      kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(CVPixelBufferGetPixelFormatType(buffer))
  }
}
