import CoreVideo
import FFmpeg
import Foundation

/// Interleaves planar integer YUV without first quantizing or subsampling it.
internal enum PlanarVideoCopy {
  static func target(for frame: UnsafeMutablePointer<AVFrame>) -> OSType? {
    guard let raw = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format)) else { return nil }
    let d = raw.pointee
    guard d.nb_components == 3, d.flags & UInt64(AV_PIX_FMT_FLAG_PLANAR) != 0,
          d.flags & UInt64(AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_BE | AV_PIX_FMT_FLAG_FLOAT) == 0,
          d.comp.0.plane == 0, d.comp.1.plane == 1, d.comp.2.plane == 2,
          [8, 9, 10, 12, 14, 16].contains(Int(d.comp.0.depth)),
          d.comp.0.depth == d.comp.1.depth, d.comp.1.depth == d.comp.2.depth,
          d.log2_chroma_w <= 1, d.log2_chroma_h <= 1 else { return nil }
    let full = frame.pointee.color_range == AVCOL_RANGE_JPEG || String(cString: d.name).hasPrefix("yuvj")
    // Common 4:2:0 already has an exact optimized copy/scaler path.
    if d.log2_chroma_w == 1, d.log2_chroma_h == 1, d.comp.0.depth <= 10 { return nil }
    if d.comp.0.depth > 10 {
      return d.log2_chroma_w == 1 && d.log2_chroma_h == 0
        ? kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange : kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
    }
    if d.comp.0.depth > 8 {
      switch (d.log2_chroma_w, d.log2_chroma_h) {
      case (1, 1): return full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      case (1, 0): return full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
      default: return full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
      }
    }
    switch (d.log2_chroma_w, d.log2_chroma_h) {
    case (1, 1): return full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case (1, 0): return full ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
    default: return full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
    }
  }

  static func write(_ frame: UnsafeMutablePointer<AVFrame>, into buffer: CVPixelBuffer, interlaced: Bool = false) throws {
    guard let raw = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format)) else {
      throw FFmpegDecoderError.unsupportedPixelFormat(frame.pointee.format)
    }
    let d = raw.pointee, bits = Int(raw.pointee.comp.0.depth)
    let word = bits > 8
    let targetBits = word ? 16 : 8
    let targetIs16 = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
      || CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
    let shift = word ? 16 - bits : 0
    let full = frame.pointee.color_range == AVCOL_RANGE_JPEG
    let sources = [frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2]
    let strides = [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2]
    for plane in 0..<2 {
      guard let destination = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else {
        throw FFmpegDecoderError.contextAllocationFailed
      }
      let columns = CVPixelBufferGetWidthOfPlane(buffer, plane)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let sourceColumns = plane == 0 ? Int(frame.pointee.width)
        : (Int(frame.pointee.width) + (1 << d.log2_chroma_w) - 1) >> d.log2_chroma_w
      let sourceRows = plane == 0 ? Int(frame.pointee.height)
        : (Int(frame.pointee.height) + (1 << d.log2_chroma_h) - 1) >> d.log2_chroma_h
      for row in 0..<rows {
        for column in 0..<columns {
          for channel in 0..<(plane == 0 ? 1 : 2) {
            let component = plane == 0 ? 0 : channel + 1
            guard let source = sources[component] else { throw FFmpegDecoderError.contextAllocationFailed }
            func read(_ x: Int, _ y: Int) -> Double {
              let address = UnsafeRawPointer(source + y * Int(strides[component]))
              return word ? Double(address.load(fromByteOffset: x * 2, as: UInt16.self))
                : Double(address.load(fromByteOffset: x, as: UInt8.self))
            }
            let value: Double
            if sourceColumns == columns && sourceRows == rows {
              value = read(column, row)
            } else {
              // Resample on the source grid, preserving its declared siting.
              // A woven frame's chroma is interpolated within each field.
              let location = frame.pointee.chroma_location
              let left = location == AVCHROMA_LOC_LEFT || location == AVCHROMA_LOC_TOPLEFT || location == AVCHROMA_LOC_BOTTOMLEFT
              let top = location == AVCHROMA_LOC_TOP || location == AVCHROMA_LOC_TOPLEFT
              let bottom = location == AVCHROMA_LOC_BOTTOM || location == AVCHROMA_LOC_BOTTOMLEFT
              let sx = sourceColumns == columns ? Double(column) : (Double(column) - (left ? 0 : 0.5)) / Double(1 << d.log2_chroma_w)
              let field = interlaced && sourceRows != rows ? row % 2 : 0
              let sourceFieldRows = interlaced && sourceRows != rows ? (sourceRows + 1 - field) / 2 : sourceRows
              let targetRow = interlaced && sourceRows != rows ? row / 2 : row
              let sy = sourceRows == rows ? Double(row)
                : (Double(targetRow) - (top ? 0 : bottom ? 1 : 0.5)) / Double(1 << d.log2_chroma_h)
              let x = max(0, min(Double(sourceColumns - 1), sx))
              let y = max(0, min(Double(max(0, sourceFieldRows - 1)), sy))
              let x0 = Int(floor(x)), x1 = min(x0 + 1, sourceColumns - 1)
              let y0 = Int(floor(y)), y1 = min(y0 + 1, max(0, sourceFieldRows - 1))
              let actualY0 = interlaced && sourceRows != rows ? min(y0 * 2 + field, sourceRows - 1) : y0
              let actualY1 = interlaced && sourceRows != rows ? min(y1 * 2 + field, sourceRows - 1) : y1
              let fx = x - Double(x0), fy = y - Double(y0)
              let a = read(x0, actualY0) * (1 - fx) + read(x1, actualY0) * fx
              let b = read(x0, actualY1) * (1 - fx) + read(x1, actualY1) * fx
              value = a * (1 - fy) + b * fy
            }
            var stored = Int((value * Double(1 << shift)).rounded())
            if full, bits == 9 {
              let code = plane == 0 ? value * 1023 / 511 : 512 + (value - 256) * 1023 / 511
              stored = Int(code.rounded()) << 6
            }
            if full, targetIs16 {
              let maxCode = Double((1 << bits) - 1)
              if plane == 0 { stored = Int((4096 + value / maxCode * 56064).rounded()) }
              else {
                stored = Int((32768 + (value - Double(1 << (bits - 1))) / maxCode * 57344).rounded())
              }
            }
            let index = column * (plane == 0 ? 1 : 2) + channel
            if targetBits == 16 { destination.storeBytes(of: UInt16(clamping: stored), toByteOffset: row * stride + index * 2, as: UInt16.self) }
            else { destination.storeBytes(of: UInt8(clamping: stored), toByteOffset: row * stride + index, as: UInt8.self) }
          }
        }
      }
    }
  }
}
