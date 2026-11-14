import FFmpeg
import Foundation

/// A format as decoded, before any conversion into a system pixel buffer.
public struct FFmpegVideoFormat: Sendable, Equatable, Codable {
  public let pixelFormatCode: Int32
  public let name: String
  public let componentDepths: [Int]
  public let storageBits: Int?
  public let chromaSubsampling: String?
  public let isRGB: Bool
  public let isFloatingPoint: Bool

  public init?(pixelFormatCode: Int32) {
    guard let raw = av_pix_fmt_desc_get(AVPixelFormat(rawValue: pixelFormatCode)),
          raw.pointee.flags & UInt64(AV_PIX_FMT_FLAG_HWACCEL) == 0 else { return nil }
    let d = raw.pointee
    self.pixelFormatCode = pixelFormatCode
    name = String(cString: d.name)
    let components = [d.comp.0, d.comp.1, d.comp.2, d.comp.3].prefix(Int(d.nb_components))
    componentDepths = components.map { Int($0.depth) }
    isRGB = d.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
    isFloatingPoint = d.flags & UInt64(AV_PIX_FMT_FLAG_FLOAT) != 0
    let depth = componentDepths.max() ?? 0
    if isRGB, components.contains(where: { $0.shift != 0 }) {
      storageBits = Int(d.comp.0.step) * 8
    } else {
      storageBits = depth > 0 && depth <= 32 && d.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) == 0
        ? ((depth + 7) / 8) * 8 : nil
    }
    if !isRGB, d.nb_components >= 3 {
      switch (d.log2_chroma_w, d.log2_chroma_h) {
      case (0, 0): chromaSubsampling = "4:4:4"
      case (1, 0): chromaSubsampling = "4:2:2"
      case (1, 1): chromaSubsampling = "4:2:0"
      case (2, 0): chromaSubsampling = "4:1:1"
      default: chromaSubsampling = "shift:\(d.log2_chroma_w),\(d.log2_chroma_h)"
      }
    } else { chromaSubsampling = nil }
  }
}
