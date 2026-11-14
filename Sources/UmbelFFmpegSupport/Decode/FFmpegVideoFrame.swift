import CoreVideo
import Foundation

/// A decoded video frame, keeping the shape of time and colour beneath.
///
/// Colour space and range come out as **raw integers**, for the layer above
/// to judge what it supports: this module does not know the domain's colour
/// types, and the dependency runs one way.
public struct FFmpegVideoFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let width: Int32
  public let height: Int32
  public let pts: Int64
  public let timeBaseNum: Int32
  public let timeBaseDen: Int32
  public let colorspace: Int32
  public let colorRange: Int32
  /// FFmpeg's transfer characteristic and colour primaries codes.
  public let colorTransfer: Int32
  public let colorPrimaries: Int32
  /// HDR10's static metadata, when the frame carries it.
  public let hdr: FFmpegHDRMetadata?
  /// The width of a pixel over its height; 0/1 when nothing says.
  public let sampleAspectNum: Int32
  public let sampleAspectDen: Int32
  /// The clockwise degrees to turn the picture by to show it upright, from
  /// the stream's declaration: 0, 90, 180 or 270.
  public let rotation: Int32
  /// Woven from two fields shown half a frame apart.
  public let isInterlaced: Bool
  /// For an interlaced frame: whether the top field (the even rows, from 0)
  /// comes first in time.
  public let topFieldFirst: Bool
  /// How long the frame shows, in its time base; 0 when not known.
  public let duration: Int64
  /// The frame rate the stream declares, as the decoder read it from the
  /// bitstream (MPEG-2's sequence header, H.264's timing information); 0/1
  /// when it declares none. A frame made of two field pictures takes its
  /// duration from the first field's packet, one field long: this is how
  /// the frame's real period is told from that.
  public let frameRateNum: Int32
  public let frameRateDen: Int32
  /// Whether hardware decoded it. Software-decoded frames go through one more
  /// copy; this is for diagnostics.
  public let wasHardwareDecoded: Bool
  public let sourceFormat: FFmpegVideoFormat?
  /// Observed decoder side data, distinct from a container presence flag.
  public let hasDynamicMetadata: Bool
  public let conversionReason: String?
  public let chromaLocationCode: Int32

  public init(
    pixelBuffer: CVPixelBuffer,
    width: Int32,
    height: Int32,
    pts: Int64,
    timeBaseNum: Int32,
    timeBaseDen: Int32,
    colorspace: Int32,
    colorRange: Int32,
    colorTransfer: Int32 = 2,
    colorPrimaries: Int32 = 2,
    hdr: FFmpegHDRMetadata? = nil,
    sampleAspectNum: Int32 = 0,
    sampleAspectDen: Int32 = 1,
    rotation: Int32 = 0,
    isInterlaced: Bool = false,
    topFieldFirst: Bool = false,
    duration: Int64 = 0,
    frameRateNum: Int32 = 0,
    frameRateDen: Int32 = 1,
    wasHardwareDecoded: Bool,
    sourceFormat: FFmpegVideoFormat?,
    hasDynamicMetadata: Bool = false, conversionReason: String? = nil, chromaLocationCode: Int32 = 0
  ) {
    self.pixelBuffer = pixelBuffer
    self.width = width
    self.height = height
    self.pts = pts
    self.timeBaseNum = timeBaseNum
    self.timeBaseDen = timeBaseDen
    self.colorspace = colorspace
    self.colorRange = colorRange
    self.colorTransfer = colorTransfer
    self.colorPrimaries = colorPrimaries
    self.hdr = hdr
    self.sampleAspectNum = sampleAspectNum
    self.sampleAspectDen = sampleAspectDen
    self.rotation = rotation
    self.isInterlaced = isInterlaced
    self.topFieldFirst = topFieldFirst
    self.duration = duration
    self.frameRateNum = frameRateNum
    self.frameRateDen = frameRateDen
    self.wasHardwareDecoded = wasHardwareDecoded
    self.sourceFormat = sourceFormat
    self.hasDynamicMetadata = hasDynamicMetadata
    self.conversionReason = conversionReason
    self.chromaLocationCode = chromaLocationCode
  }
}
