import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Packages dynamic video for system decode and display. Compatible bases
/// retain their transfer; the native pixel adapter can prepare late headers.
///
/// A packet that brings other codec parameters — a playlist run encoded
/// otherwise — gets a packager made for them. Nothing is held back: what
/// is packaged goes out at once, and the system keeps it.
internal actor SystemDecodeSession: VideoFrameSource {
  private var packager: DVSamplePackager
  private var parameters: FFmpegCodecParameters
  private var record: FFmpegDOVIConfiguration
  private let preparesParameterSets: Bool
  private var parameterSetOrder: HEVCParameterSetOrder?
  /// Informative: the system decides what the picture is.
  private var color: VideoColorDescription {
    .init(matrix: .bt2020, range: .limited,
          transfer: record.compatibility == 4 ? .hlg : record.compatibility == 2 ? .sdr : .pq,
          primaries: .bt2020)
  }

  /// `primed`: parameter sets found at the stream's start, for a stream
  /// that carries none in its setup bytes.
  internal init(
    parameters: FFmpegCodecParameters, record: FFmpegDOVIConfiguration,
    primed: HEVCParameterSets.Sets? = nil, preparesParameterSets: Bool = false
  ) throws {
    self.parameters = parameters
    self.record = record
    self.preparesParameterSets = preparesParameterSets
    parameterSetOrder = preparesParameterSets
      ? HEVCParameterSetOrder(lengthSize: parameters.extradata.first == 1
        ? HEVCParameterSets.lengthSize(ofHvcC: parameters.extradata) : nil) : nil
    self.packager = try DVSamplePackager(
      extradata: parameters.extradata, record: record,
      width: parameters.width, height: parameters.height, primed: primed)
  }

  internal func decode(_ packet: DemuxPacket, hidden: Bool) throws -> [VideoFrame] {
    if let changed = packet.decoderParameters, changed !== parameters {
      parameters = changed
      guard let changedRecord = changed.dovi else {
        throw UmbelError.unsupportedDynamicHDR("missing dynamic configuration after format change")
      }
      record = changedRecord
      if preparesParameterSets {
        parameterSetOrder = HEVCParameterSetOrder(lengthSize: changed.extradata.first == 1
          ? HEVCParameterSets.lengthSize(ofHvcC: changed.extradata) : nil)
      }
      packager = try DVSamplePackager(
        extradata: changed.extradata, record: changed.dovi ?? record,
        width: changed.width, height: changed.height)
    }
    guard let sample = try packager.sample(
      data: parameterSetOrder?.prepare(packet.data) ?? packet.data, presentationTime: packet.presentationTime,
      decodeTime: packet.decodeTime, isKeyframe: packet.isKeyframe, hidden: hidden) else { return [] }
    return [VideoFrame(
      presentationTime: packet.presentationTime, compressed: sample,
      width: parameters.width, height: parameters.height, color: color, isShown: !hidden)]
  }

  internal func drain() throws -> [VideoFrame] { [] }

  internal func flush() { packager.reset(); parameterSetOrder?.reset() }

  /// The system decodes: there is no decoder of ours to make again.
  internal func renew() { flush() }

  internal func close() {}

  /// The system drops what it cannot show in time itself.
  internal func setSkipsNonReference(_ skips: Bool) {}

  internal var skipsNonReference: Bool { false }
}
