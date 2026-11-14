import FFmpeg
import Foundation

/// A copy of one stream's codec parameters, kept after the demuxer that
/// described them is gone: what a decoder is made from.
///
/// A playlist is demuxed a run at a time, and a run can be encoded
/// otherwise than the one before — an ad spliced in. Packets carry the
/// parameters they decode with, and a decoder is made again when they
/// change.
public final class FFmpegCodecParameters: @unchecked Sendable {
  private let parameters: UnsafeMutablePointer<AVCodecParameters>
  private let timeBaseNum: Int32
  private let timeBaseDen: Int32
  private let sampleAspect: AVRational

  internal init?(
    copying source: UnsafePointer<AVCodecParameters>,
    timeBaseNum: Int32, timeBaseDen: Int32, sampleAspect: AVRational
  ) {
    guard let copy = avcodec_parameters_alloc() else { return nil }
    guard avcodec_parameters_copy(copy, source) >= 0 else {
      var mutable: UnsafeMutablePointer<AVCodecParameters>? = copy
      avcodec_parameters_free(&mutable)
      return nil
    }
    self.parameters = copy
    self.timeBaseNum = timeBaseNum
    self.timeBaseDen = timeBaseDen
    self.sampleAspect = sampleAspect
  }

  deinit {
    var mutable: UnsafeMutablePointer<AVCodecParameters>? = parameters
    avcodec_parameters_free(&mutable)
  }

  /// Whether a decoder made for the other would do for this: the same
  /// codec, picture size, rate, channels and codec setup bytes.
  public func isSameFormat(as other: FFmpegCodecParameters) -> Bool {
    let a = parameters.pointee
    let b = other.parameters.pointee
    guard a.codec_id == b.codec_id, a.width == b.width, a.height == b.height,
          a.format == b.format, a.color_range == b.color_range, a.color_space == b.color_space,
          a.color_trc == b.color_trc, a.color_primaries == b.color_primaries, dovi == other.dovi,
          a.sample_rate == b.sample_rate,
          a.ch_layout.nb_channels == b.ch_layout.nb_channels,
          a.extradata_size == b.extradata_size else { return false }
    guard a.extradata_size > 0, let left = a.extradata, let right = b.extradata else { return true }
    return memcmp(left, right, Int(a.extradata_size)) == 0
  }

  /// The codec's profile as FFmpeg numbers it; for E-AC-3, 30 marks joint
  /// object coding. `FF_PROFILE_UNKNOWN` (-99) when not known.
  public var profile: Int32 { parameters.pointee.profile }

  /// The parameters themselves, for writers in this module.
  internal func withUnsafeParameters<T>(_ body: (UnsafePointer<AVCodecParameters>) throws -> T) rethrows -> T {
    try body(parameters)
  }

  /// The codec's setup bytes: for HEVC in MP4 or Matroska, its hvcC record.
  public var extradata: Data {
    guard let bytes = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 else {
      return Data()
    }
    return Data(bytes: bytes, count: Int(parameters.pointee.extradata_size))
  }

  public var width: Int { Int(parameters.pointee.width) }
  public var height: Int { Int(parameters.pointee.height) }

  /// The declared source representation, before a decoder requests an output
  /// pixel buffer. An unknown declaration remains unknown.
  public var videoFormat: FFmpegVideoFormat? {
    FFmpegVideoFormat(pixelFormatCode: parameters.pointee.format)
  }

  /// The source color declarations, with their original unspecified values.
  public var colorTransfer: Int32 { Int32(parameters.pointee.color_trc.rawValue) }
  public var colorPrimaries: Int32 { Int32(parameters.pointee.color_primaries.rawValue) }
  public var colorMatrix: Int32 { Int32(parameters.pointee.color_space.rawValue) }
  public var colorRange: Int32 { Int32(parameters.pointee.color_range.rawValue) }

  /// The DV configuration record, when the stream is DV.
  public var dovi: FFmpegDOVIConfiguration? {
    FFmpegDOVIConfiguration(codecParameters: parameters)
  }

  /// The clockwise degrees the stream's display matrix turns the picture by.
  public var rotation: Int32 {
    FFmpegDisplayRotation.clockwiseDegrees(codecParameters: parameters)
  }

  public func makeAudioDecoder() throws -> FFmpegAudioDecoder {
    let decoder = try FFmpegAudioDecoder(
      parameters: parameters, timeBaseNum: timeBaseNum, timeBaseDen: timeBaseDen)
    decoder.parameters = self
    return decoder
  }

  /// `softwareThreadCount` applies to software decoding only; 0 leaves the
  /// count to FFmpeg.
  public func makeVideoDecoder(
    preferHardware: Bool, softwareThreadCount: Int32 = 0
  ) throws -> FFmpegVideoDecoder {
    let decoder = try FFmpegVideoDecoder(
      parameters: parameters, timeBaseNum: timeBaseNum, timeBaseDen: timeBaseDen,
      containerAspect: sampleAspect, containerRotation: rotation, preferHardware: preferHardware,
      softwareThreadCount: softwareThreadCount)
    decoder.parameters = self
    return decoder
  }
}
