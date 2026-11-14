import FFmpeg
import Foundation

/// A file attached to a container, such as a font in a Matroska file.
public struct FFmpegAttachment: Sendable {
  public let filename: String?
  public let mimeType: String?
  public let data: Data
}

/// Read-only questions about an opened format context.
///
/// Kept apart from `FFmpegDemuxer`, which owns the context and drives it:
/// these only look, and take the context as an argument. They must still be
/// called on the demuxer's worker thread, like everything touching it.
internal enum FFmpegFormatInspection {
  static func stream(
    _ index: Int32, in context: UnsafeMutablePointer<AVFormatContext>
  ) -> UnsafeMutablePointer<AVStream>? {
    guard index >= 0, index < Int32(context.pointee.nb_streams),
          let streams = context.pointee.streams else { return nil }
    return streams[Int(index)]
  }

  static func streams(in context: UnsafeMutablePointer<AVFormatContext>) -> [FFmpegStreamInfo] {
    (0..<Int32(context.pointee.nb_streams)).compactMap { index in
      guard let stream = stream(index, in: context) else { return nil }
      let parameters = stream.pointee.codecpar.pointee

      let mediaType: FFmpegMediaType
      switch parameters.codec_type {
      case AVMEDIA_TYPE_VIDEO: mediaType = .video
      case AVMEDIA_TYPE_AUDIO: mediaType = .audio
      case AVMEDIA_TYPE_SUBTITLE: mediaType = .subtitle
      default: mediaType = .other
      }

      let name = avcodec_get_name(parameters.codec_id).map { String(cString: $0) } ?? "unknown"
      let disposition = stream.pointee.disposition
      // The container's word first, then the bitstream's.
      let aspect = av_guess_sample_aspect_ratio(context, stream, nil)
      return FFmpegStreamInfo(
        index: index,
        mediaType: mediaType,
        codecName: name,
        language: metadataValue(stream.pointee.metadata, key: "language"),
        title: metadataValue(stream.pointee.metadata, key: "title"),
        isDefault: disposition & AV_DISPOSITION_DEFAULT != 0,
        isForced: disposition & AV_DISPOSITION_FORCED != 0,
        width: parameters.width,
        height: parameters.height,
        frameRateNum: stream.pointee.avg_frame_rate.num,
        frameRateDen: stream.pointee.avg_frame_rate.den,
        channelCount: parameters.ch_layout.nb_channels,
        sampleRate: parameters.sample_rate,
        sampleAspectNum: aspect.num,
        sampleAspectDen: aspect.den,
        rotation: FFmpegDisplayRotation.clockwiseDegrees(codecParameters: stream.pointee.codecpar),
        colorTransfer: Int32(parameters.color_trc.rawValue),
        dovi: FFmpegDOVIConfiguration(codecParameters: stream.pointee.codecpar),
        hasDecoder: avcodec_find_decoder(parameters.codec_id) != nil,
        videoFormat: FFmpegVideoFormat(pixelFormatCode: parameters.format),
        colorPrimaries: Int32(parameters.color_primaries.rawValue),
        colorMatrix: Int32(parameters.color_space.rawValue),
        colorRange: Int32(parameters.color_range.rawValue)
      )
    }
  }

  /// FFmpeg exposes attachments as streams of their own type, the file's
  /// bytes in the stream's extradata.
  static func attachments(in context: UnsafeMutablePointer<AVFormatContext>) -> [FFmpegAttachment] {
    (0..<Int32(context.pointee.nb_streams)).compactMap { index in
      guard let stream = stream(index, in: context),
            stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT else { return nil }
      let parameters = stream.pointee.codecpar.pointee
      guard let bytes = parameters.extradata, parameters.extradata_size > 0 else { return nil }
      return FFmpegAttachment(
        filename: metadataValue(stream.pointee.metadata, key: "filename"),
        mimeType: metadataValue(stream.pointee.metadata, key: "mimetype"),
        data: Data(bytes: bytes, count: Int(parameters.extradata_size)))
    }
  }

  /// The latest index entry of a stream at or before `seconds`, in seconds.
  static func latestIndexedTime(
    in context: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int32, atOrBefore seconds: Double
  ) -> Double? {
    guard let stream = stream(streamIndex, in: context) else { return nil }
    let base = stream.pointee.time_base
    guard base.num > 0, base.den > 0 else { return nil }
    let timestamp = Int64((seconds * Double(base.den) / Double(base.num)).rounded(.down))
    let found = av_index_search_timestamp(stream, timestamp, AVSEEK_FLAG_BACKWARD)
    guard found >= 0, let entry = avformat_index_get_entry(stream, found) else { return nil }
    return Double(entry.pointee.timestamp) * Double(base.num) / Double(base.den)
  }

  static func metadataValue(_ dictionary: OpaquePointer?, key: String) -> String? {
    guard let dictionary, let entry = av_dict_get(dictionary, key, nil, 0),
          let value = entry.pointee.value else { return nil }
    let string = String(cString: value)
    return string.isEmpty ? nil : string
  }
}
