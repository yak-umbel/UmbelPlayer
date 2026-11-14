import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Turns FFmpeg-shaped neutral structures into domain types.
///
/// Pure functions throughout: no I/O, no state, no context beneath, so table
/// tests can cover them widely, edges hard to build into real files
/// included (zero denominators, missing timestamps).
internal enum TrackMapping {
  /// Media types that do not map (data tracks, attachments) give nil, and
  /// the caller drops them.
  internal static func track(from info: FFmpegStreamInfo) -> UmbelTrack? {
    let kind: UmbelTrack.Kind
    switch info.mediaType {
    case .video: kind = .video
    case .audio: kind = .audio
    case .subtitle: kind = .subtitle
    case .other: return nil
    }

    let dynamic = info.dovi.map {
      UmbelDynamicHDR.dv(profile: $0.profile, level: $0.level, compatibility: $0.compatibility)
    }
    return UmbelTrack(
      id: UmbelTrack.ID(rawValue: info.index),
      kind: kind,
      codecName: info.codecName,
      language: nonEmpty(info.language),
      title: nonEmpty(info.title),
      isDefault: info.isDefault,
      // Forced means something for subtitles only; cleared on any other
      // track, whatever the container says.
      isForced: kind == .subtitle && info.isForced,
      video: kind == .video
        ? UmbelTrack.VideoDescription(
            width: Int(info.width),
            height: Int(info.height),
            nominalFrameRate: frameRate(num: info.frameRateNum, den: info.frameRateDen),
            pixelAspectRatio: pixelAspectRatio(num: info.sampleAspectNum, den: info.sampleAspectDen),
            transfer: transfer(declared: info.colorTransfer, baseLayer: dynamic?.baseLayer),
            dynamicHDR: dynamic,
            rotation: UmbelVideoRotation(clockwiseDegrees: info.rotation),
            signal: VideoSignalDescription(
              pixels: info.videoFormat.map(VideoPixelDescription.init(ffmpeg:)),
              transferCode: info.colorTransfer, primariesCode: info.colorPrimaries,
              matrixCode: info.colorMatrix, rangeCode: info.colorRange, dynamicHDR: dynamic)
          )
        : nil,
      audio: kind == .audio
        ? UmbelTrack.AudioDescription(
            channelCount: Int(info.channelCount),
            sampleRate: Int(info.sampleRate)
          )
        : nil,
      isDecodable: info.hasDecoder
    )
  }

  /// The declared transfer; where none is declared (FFmpeg's 2, and 0),
  /// a DV base layer's, as its configuration names it.
  internal static func transfer(declared: Int32, baseLayer: UmbelDVBaseLayer?) -> UmbelTransferFunction {
    if let baseLayer, declared == 2 || declared == 0 { return baseLayer.transfer }
    return UmbelTransferFunction(ffmpegCode: declared)
  }

  /// Integer ticks in a stream's time base as a time. A missing timestamp
  /// or a bad time base gives `.invalid` — never 0 or inf.
  internal static func time(ticks: Int64, num: Int32, den: Int32) -> CMTime {
    guard ticks != FFmpegPacket.noTimestamp, num > 0, den > 0 else { return .invalid }
    // value / timescale = ticks * num / den
    return CMTime(value: ticks * Int64(num), timescale: CMTimeScale(den))
  }

  /// Square when undeclared or nonsensical.
  internal static func pixelAspectRatio(num: Int32, den: Int32) -> Double {
    guard num > 0, den > 0 else { return 1 }
    return Double(num) / Double(den)
  }

  private static func frameRate(num: Int32, den: Int32) -> Double? {
    guard num > 0, den > 0 else { return nil }
    return Double(num) / Double(den)
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
