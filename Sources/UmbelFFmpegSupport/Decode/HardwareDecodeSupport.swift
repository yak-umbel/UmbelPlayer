import CoreMedia
import FFmpeg
import Foundation
import VideoToolbox

/// Whether VideoToolbox can decode a stream in hardware, asked before the
/// decoder opens.
///
/// Attached to a stream the hardware cannot decode, the device makes FFmpeg
/// fall back to software only once decoding has begun, and then on one
/// thread: threads are settled when the decoder opens. MPEG-4 Part 2, 10-bit
/// H.264, and AV1 before the chips that have it all went that way.
internal enum HardwareDecodeSupport {
  /// For a stream as the container describes it.
  static func canDecode(_ parameters: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
    canDecode(
      codec: parameters.pointee.codec_id,
      format: AVPixelFormat(rawValue: parameters.pointee.format),
      hardwareSupports: supportsInHardware)
  }

  /// `format` is AV_PIX_FMT_NONE when the container does not say; then the
  /// hardware is tried.
  static func canDecode(
    codec: AVCodecID, format: AVPixelFormat,
    hardwareSupports: (CMVideoCodecType) -> Bool
  ) -> Bool {
    guard let type = codecType(for: codec), hardwareSupports(type) else { return false }
    switch format {
    case AV_PIX_FMT_NONE, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUVJ420P:
      return true
    case AV_PIX_FMT_YUV420P10LE:
      // The hardware decodes H.264 at 8 bits only.
      return type != kCMVideoCodecType_H264
    default:
      // 4:2:2, 4:4:4 and deeper: software.
      return false
    }
  }

  /// The codecs FFmpeg decodes through VideoToolbox.
  private static func codecType(for codec: AVCodecID) -> CMVideoCodecType? {
    switch codec {
    case AV_CODEC_ID_H264: return kCMVideoCodecType_H264
    case AV_CODEC_ID_HEVC: return kCMVideoCodecType_HEVC
    case AV_CODEC_ID_MPEG1VIDEO: return kCMVideoCodecType_MPEG1Video
    case AV_CODEC_ID_MPEG2VIDEO: return kCMVideoCodecType_MPEG2Video
    case AV_CODEC_ID_MPEG4: return kCMVideoCodecType_MPEG4Video
    case AV_CODEC_ID_VP9: return kCMVideoCodecType_VP9
    case AV_CODEC_ID_AV1: return kCMVideoCodecType_AV1
    default: return nil
    }
  }

  private static func supportsInHardware(_ type: CMVideoCodecType) -> Bool {
    #if os(macOS)
    // On the Mac, VP9 and AV1 come as supplemental decoders, known to
    // VideoToolbox only once asked for.
    if type == kCMVideoCodecType_VP9 || type == kCMVideoCodecType_AV1 {
      VTRegisterSupplementalVideoDecoderIfAvailable(type)
    }
    #endif
    return VTIsHardwareDecodeSupported(type)
  }
}
