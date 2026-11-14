import FFmpeg
import Foundation

/// HDR10's static metadata as FFmpeg attaches it to a decoded frame: from
/// HEVC's SEI messages, or from the container for VP9 and Matroska.
public struct FFmpegHDRMetadata: Sendable, Equatable {
  /// Red, green, blue and white point, x then y for each; nil when the
  /// mastering display's colours are not given.
  public let primaries: [Double]?
  /// The mastering display's range, in nits.
  public let minLuminance: Double?
  public let maxLuminance: Double?
  /// MaxCLL and MaxFALL, in nits.
  public let maxContentLightLevel: Int?
  public let maxFrameAverageLightLevel: Int?

  public init(
    primaries: [Double]?, minLuminance: Double?, maxLuminance: Double?,
    maxContentLightLevel: Int?, maxFrameAverageLightLevel: Int?
  ) {
    self.primaries = primaries
    self.minLuminance = minLuminance
    self.maxLuminance = maxLuminance
    self.maxContentLightLevel = maxContentLightLevel
    self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
  }

  /// What `frame` carries; nil when it carries neither kind.
  internal init?(frame: UnsafeMutablePointer<AVFrame>) {
    var primaries: [Double]?
    var minLuminance: Double?
    var maxLuminance: Double?
    if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
       let data = side.pointee.data {
      let mastering = UnsafeRawPointer(data).load(as: AVMasteringDisplayMetadata.self)
      if mastering.has_primaries != 0 {
        let p = mastering.display_primaries   // red, green, blue
        let w = mastering.white_point
        primaries = [p.0.0, p.0.1, p.1.0, p.1.1, p.2.0, p.2.1, w.0, w.1].map(Self.value)
      }
      if mastering.has_luminance != 0 {
        minLuminance = Self.value(mastering.min_luminance)
        maxLuminance = Self.value(mastering.max_luminance)
      }
    }
    var maxContent: Int?
    var maxAverage: Int?
    if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
       let data = side.pointee.data {
      let light = UnsafeRawPointer(data).load(as: AVContentLightMetadata.self)
      maxContent = Int(light.MaxCLL)
      maxAverage = Int(light.MaxFALL)
    }
    guard primaries != nil || maxLuminance != nil || maxContent != nil else { return nil }
    self.init(
      primaries: primaries, minLuminance: minLuminance, maxLuminance: maxLuminance,
      maxContentLightLevel: maxContent, maxFrameAverageLightLevel: maxAverage)
  }

  private static func value(_ rational: AVRational) -> Double {
    rational.den == 0 ? 0 : Double(rational.num) / Double(rational.den)
  }
}
