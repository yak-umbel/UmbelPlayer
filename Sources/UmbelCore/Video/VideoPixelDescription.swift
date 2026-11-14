import CoreVideo
import Foundation
import UmbelFFmpegSupport

/// A sample's representation, not a claim about the display panel.
public struct VideoPixelDescription: Sendable, Equatable, Codable {
  public let format: String
  public let effectiveBits: Int?
  public let storageBits: Int?
  public let chromaSubsampling: String?
  public let isRGB: Bool
  public let isFloatingPoint: Bool
  public let componentBits: [Int]?

  public init(cvFormat: OSType) {
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: cvFormat >> (24 - $0 * 8)) }
    format = String(bytes: bytes, encoding: .ascii).flatMap {
      $0.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 } ? $0 : nil
    } ?? String(cvFormat)
    let description: (Int?, Int?, String?, Bool, Bool)
    switch cvFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      description = (8, 8, "4:2:0", false, false)
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
      description = (8, 8, "4:2:2", false, false)
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
      description = (8, 8, "4:4:4", false, false)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      description = (10, 16, "4:2:0", false, false)
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
      description = (10, 16, "4:2:2", false, false)
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
      description = (10, 16, "4:4:4", false, false)
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
      description = (16, 16, "4:2:2", false, false)
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
      description = (16, 16, "4:4:4", false, false)
    case kCVPixelFormatType_32BGRA: description = (8, 8, nil, true, false)
    case kCVPixelFormatType_64RGBALE: description = (16, 16, nil, true, false)
    case kCVPixelFormatType_64RGBAHalf: description = (nil, 16, nil, true, true)
    case kCVPixelFormatType_128RGBAFloat: description = (nil, 32, nil, true, true)
    default: description = (nil, nil, nil, false, false)
    }
    (effectiveBits, storageBits, chromaSubsampling, isRGB, isFloatingPoint) = description
    componentBits = description.0.map { Array(repeating: $0, count: description.3 ? 4 : 3) }
  }

  internal init(ffmpeg: FFmpegVideoFormat) {
    format = ffmpeg.name
    effectiveBits = ffmpeg.isFloatingPoint ? nil : ffmpeg.componentDepths.max()
    storageBits = ffmpeg.storageBits
    chromaSubsampling = ffmpeg.chromaSubsampling
    isRGB = ffmpeg.isRGB
    isFloatingPoint = ffmpeg.isFloatingPoint
    componentBits = ffmpeg.componentDepths
  }
}
