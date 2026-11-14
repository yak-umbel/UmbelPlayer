import Foundation

public enum FFmpegMediaType: String, Sendable, Equatable {
  case video
  case audio
  case subtitle
  case other
}

/// A stream's description, in FFmpeg's own shape.
///
/// Deliberately not a domain type: the frame rate is a numerator and a
/// denominator rather than a Double, the language a raw string rather than
/// an enumeration. Pure functions above translate it, so table tests can
/// cover the translation widely without opening a file.
public struct FFmpegStreamInfo: Sendable, Equatable {
  public let index: Int32
  public let mediaType: FFmpegMediaType
  public let codecName: String
  public let language: String?
  public let title: String?
  public let isDefault: Bool
  public let isForced: Bool
  public let width: Int32
  public let height: Int32
  public let frameRateNum: Int32
  public let frameRateDen: Int32
  public let channelCount: Int32
  public let sampleRate: Int32
  /// The width of a pixel over its height, as FFmpeg guesses it from the
  /// container and the bitstream. 0/1 when neither says.
  public let sampleAspectNum: Int32
  public let sampleAspectDen: Int32
  /// The clockwise degrees the stream's display matrix says to turn the
  /// picture by to show it upright: 0, 90, 180 or 270. 0 when it declares
  /// none, flips the picture, or asks for an angle that is no right angle.
  public let rotation: Int32
  /// FFmpeg's transfer characteristic code, as the container or the
  /// stream's parameter sets declare it.
  public let colorTransfer: Int32
  /// The DV configuration record, when the stream is DV.
  public let dovi: FFmpegDOVIConfiguration?
  /// Whether this build of FFmpeg has a decoder for the stream's codec.
  public let hasDecoder: Bool
  public let videoFormat: FFmpegVideoFormat?
  public let colorPrimaries: Int32
  public let colorMatrix: Int32
  public let colorRange: Int32

  public init(
    index: Int32,
    mediaType: FFmpegMediaType,
    codecName: String,
    language: String?,
    title: String?,
    isDefault: Bool,
    isForced: Bool,
    width: Int32,
    height: Int32,
    frameRateNum: Int32,
    frameRateDen: Int32,
    channelCount: Int32,
    sampleRate: Int32,
    sampleAspectNum: Int32 = 0,
    sampleAspectDen: Int32 = 1,
    rotation: Int32 = 0,
    colorTransfer: Int32 = 2,
    dovi: FFmpegDOVIConfiguration? = nil,
    hasDecoder: Bool = true,
    videoFormat: FFmpegVideoFormat?,
    colorPrimaries: Int32 = 2, colorMatrix: Int32 = 2, colorRange: Int32 = 0
  ) {
    self.index = index
    self.mediaType = mediaType
    self.codecName = codecName
    self.language = language
    self.title = title
    self.isDefault = isDefault
    self.isForced = isForced
    self.width = width
    self.height = height
    self.frameRateNum = frameRateNum
    self.frameRateDen = frameRateDen
    self.channelCount = channelCount
    self.sampleRate = sampleRate
    self.sampleAspectNum = sampleAspectNum
    self.sampleAspectDen = sampleAspectDen
    self.rotation = rotation
    self.colorTransfer = colorTransfer
    self.dovi = dovi
    self.hasDecoder = hasDecoder
    self.videoFormat = videoFormat
    self.colorPrimaries = colorPrimaries
    self.colorMatrix = colorMatrix
    self.colorRange = colorRange
  }
}
