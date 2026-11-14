import FFmpeg
import Foundation

/// A DV stream's configuration record, as the container declares it: which
/// profile and level, which layers are present, and what the base layer is
/// compatible with on its own.
///
/// FFmpeg reads it from the MP4 sample entry, the Matroska block addition
/// or the transport stream descriptor; this carries it out of the codec
/// parameters, and writes it back into the box an MP4 sample entry carries,
/// for a sample description the system reads.
public struct FFmpegDOVIConfiguration: Sendable, Equatable {
  public let versionMajor: Int
  public let versionMinor: Int
  public let profile: Int
  public let level: Int
  public let hasRPU: Bool
  public let hasEnhancementLayer: Bool
  public let hasBaseLayer: Bool
  /// What the base layer is compatible with: 0 nothing (profile 5), 1 HDR10,
  /// 2 SDR, 4 HLG, 6 the HDR10 of a disc.
  public let compatibility: Int
  public let metadataCompression: Int

  public init(
    versionMajor: Int, versionMinor: Int, profile: Int, level: Int,
    hasRPU: Bool, hasEnhancementLayer: Bool, hasBaseLayer: Bool,
    compatibility: Int, metadataCompression: Int
  ) {
    self.versionMajor = versionMajor
    self.versionMinor = versionMinor
    self.profile = profile
    self.level = level
    self.hasRPU = hasRPU
    self.hasEnhancementLayer = hasEnhancementLayer
    self.hasBaseLayer = hasBaseLayer
    self.compatibility = compatibility
    self.metadataCompression = metadataCompression
  }

  /// From a stream's codec parameters; nil when they carry no record.
  internal init?(codecParameters parameters: UnsafePointer<AVCodecParameters>) {
    guard let side = av_packet_side_data_get(
            parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data,
            AV_PKT_DATA_DOVI_CONF),
          side.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size,
          let bytes = side.pointee.data else { return nil }
    let record = UnsafeRawPointer(bytes).loadUnaligned(as: AVDOVIDecoderConfigurationRecord.self)
    self.init(
      versionMajor: Int(record.dv_version_major), versionMinor: Int(record.dv_version_minor),
      profile: Int(record.dv_profile), level: Int(record.dv_level),
      hasRPU: record.rpu_present_flag != 0, hasEnhancementLayer: record.el_present_flag != 0,
      hasBaseLayer: record.bl_present_flag != 0,
      compatibility: Int(record.dv_bl_signal_compatibility_id),
      metadataCompression: Int(record.dv_md_compression))
  }

  /// The box's name in an MP4 sample entry: by profile.
  public var boxType: String {
    switch profile {
    case ...7: return "dvcC"
    case 8...10: return "dvvC"
    default: return "dvwC"
    }
  }

  /// The box's 24 bytes: the version, then profile, level and the three
  /// presence flags packed into 16 bits, then the compatibility and the
  /// metadata compression, the rest reserved and zero.
  public var boxPayload: Data {
    let flags = UInt16(profile) << 9 | UInt16(level) << 3
      | (hasRPU ? 4 : 0) | (hasEnhancementLayer ? 2 : 0) | (hasBaseLayer ? 1 : 0)
    var bytes: [UInt8] = [
      UInt8(versionMajor), UInt8(versionMinor), UInt8(flags >> 8), UInt8(flags & 0xFF),
      UInt8(compatibility << 4 | metadataCompression << 2),
    ]
    bytes += [UInt8](repeating: 0, count: 19)
    return Data(bytes)
  }
}
