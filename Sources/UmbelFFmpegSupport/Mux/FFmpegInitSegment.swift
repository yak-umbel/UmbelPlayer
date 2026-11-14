import FFmpeg
import Foundation

/// The initialization segment of fragmented MP4 for one stream — `ftyp` and
/// `moov` — as FFmpeg's MP4 writer makes it.
///
/// For E-AC-3 the stream description that writer puts in the sample entry
/// comes from parsing frames, not from the container's setup bytes, which a
/// Matroska track usually leaves empty. So a few leading packets go through
/// it; the fragments it would write after them are dropped, and the caller
/// writes its own, each at its own place in time.
public enum FFmpegInitSegment {
  public enum Failure: Error, Sendable, Equatable {
    /// A step of FFmpeg's writer failed, with its code.
    case writer(step: String, code: Int32)
    /// What the writer wrote held no `moov`.
    case noMovieBox
  }

  public static func make(parameters: FFmpegCodecParameters, packets: [FFmpegPacket]) throws -> Data {
    var made: UnsafeMutablePointer<AVFormatContext>?
    var code = avformat_alloc_output_context2(&made, nil, "mp4", nil)
    guard code >= 0, let context = made else { throw Failure.writer(step: "context", code: code) }
    defer { avformat_free_context(context) }
    guard let stream = avformat_new_stream(context, nil) else { throw Failure.writer(step: "stream", code: -1) }
    code = parameters.withUnsafeParameters { avcodec_parameters_copy(stream.pointee.codecpar, $0) }
    guard code >= 0 else { throw Failure.writer(step: "parameters", code: code) }
    stream.pointee.codecpar.pointee.codec_tag = 0
    let timeBase = AVRational(num: packets.first?.timeBaseNum ?? 1, den: packets.first?.timeBaseDen ?? 1_000_000)
    stream.pointee.time_base = timeBase
    // Matroska leaves the samples per frame unsaid; the writer warns without
    // them. A packet's length gives them.
    if stream.pointee.codecpar.pointee.frame_size == 0, let first = packets.first, first.duration > 0 {
      let rate = Int64(stream.pointee.codecpar.pointee.sample_rate)
      let samples = av_rescale_q(first.duration, timeBase, AVRational(num: 1, den: Int32(clamping: rate)))
      if samples > 0, samples <= Int64(Int32.max) { stream.pointee.codecpar.pointee.frame_size = Int32(samples) }
    }

    var output: UnsafeMutablePointer<AVIOContext>?
    code = avio_open_dyn_buf(&output)
    guard code >= 0, let buffer = output else { throw Failure.writer(step: "buffer", code: code) }
    context.pointee.pb = buffer
    let bytes: Data
    do {
      try writeHeaderAndPackets(context: context, stream: stream, timeBase: timeBase, packets: packets)
      bytes = closed(buffer)
    } catch {
      _ = closed(buffer)
      context.pointee.pb = nil
      throw error
    }
    context.pointee.pb = nil
    return try movieBoxes(in: bytes)
  }

  private static func writeHeaderAndPackets(
    context: UnsafeMutablePointer<AVFormatContext>, stream: UnsafeMutablePointer<AVStream>,
    timeBase: AVRational, packets: [FFmpegPacket]
  ) throws {
    var options: OpaquePointer?
    // The movie box waits for the first fragment, by when the frames have
    // been parsed for the stream description.
    av_dict_set(&options, "movflags", "frag_custom+delay_moov+default_base_moof", 0)
    let code = avformat_write_header(context, &options)
    av_dict_free(&options)
    guard code >= 0 else { throw Failure.writer(step: "header", code: code) }
    for packet in packets { try write(packet, to: context, stream: stream, from: timeBase) }
    // A null packet ends the fragment, writing the delayed movie box before it.
    let flushed = av_write_frame(context, nil)
    guard flushed >= 0 else { throw Failure.writer(step: "flush", code: flushed) }
  }

  private static func write(
    _ packet: FFmpegPacket, to context: UnsafeMutablePointer<AVFormatContext>,
    stream: UnsafeMutablePointer<AVStream>, from timeBase: AVRational
  ) throws {
    guard let made = av_packet_alloc() else { throw Failure.writer(step: "packet", code: -1) }
    defer { var freed: UnsafeMutablePointer<AVPacket>? = made; av_packet_free(&freed) }
    guard av_new_packet(made, Int32(packet.data.count)) >= 0 else { throw Failure.writer(step: "packet", code: -1) }
    packet.data.withUnsafeBytes { raw in
      if let base = raw.baseAddress { made.pointee.data.update(from: base.assumingMemoryBound(to: UInt8.self), count: raw.count) }
    }
    made.pointee.pts = packet.pts
    made.pointee.dts = packet.dts == FFmpegPacket.noTimestamp ? packet.pts : packet.dts
    made.pointee.duration = packet.duration
    made.pointee.stream_index = 0
    made.pointee.flags = packet.isKeyframe ? AV_PKT_FLAG_KEY : 0
    // The writer may have chosen its own time base for the stream.
    av_packet_rescale_ts(made, timeBase, stream.pointee.time_base)
    let code = av_write_frame(context, made)
    guard code >= 0 else { throw Failure.writer(step: "frame", code: code) }
  }

  private static func closed(_ buffer: UnsafeMutablePointer<AVIOContext>) -> Data {
    var bytes: UnsafeMutablePointer<UInt8>?
    let size = avio_close_dyn_buf(buffer, &bytes)
    defer { av_free(bytes) }
    guard let bytes, size > 0 else { return Data() }
    return Data(bytes: bytes, count: Int(size))
  }

  /// The boxes up to and including `moov`: what comes after is fragments.
  private static func movieBoxes(in bytes: Data) throws -> Data {
    var offset = 0
    while offset + 8 <= bytes.count {
      let size = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
      let type = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
      guard size >= 8, offset + size <= bytes.count else { break }
      offset += size
      if type == "moov" { return Data(bytes.prefix(offset)) }
    }
    throw Failure.noMovieBox
  }
}
