import FFmpeg
import Foundation

/// One picture of a bitmap subtitle, placed on the subtitle canvas.
public struct FFmpegSubtitleBitmap: Sendable, Equatable {
  /// Top-left corner on the canvas, in canvas pixels.
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int
  /// Premultiplied B, G, R, A bytes, `width * 4` to a row.
  public let pixels: Data
}

/// One decoded subtitle event, still in FFmpeg's terms.
///
/// An event with neither lines nor bitmaps clears the screen: PGS and DVB
/// end what is showing that way.
public struct FFmpegSubtitle: Sendable, Equatable {
  public let startMicroseconds: Int64
  /// Nil when neither the decoder nor the packet said how long it lasts.
  public let endMicroseconds: Int64?
  /// ASS dialogue lines: `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,
  /// Effect,Text`. Every text format arrives in this shape.
  public let assLines: [String]
  /// Bitmap formats: PGS, DVD, DVB.
  public let bitmaps: [FFmpegSubtitleBitmap]
  /// The picture size the bitmaps are placed on, zero when the stream does
  /// not say. PGS and DVD state it; DVB defaults to 720×576.
  public let canvasWidth: Int
  public let canvasHeight: Int
}

/// Subtitle decoder: packets in, ASS dialogue lines or bitmaps out.
///
/// FFmpeg's subrip, webvtt, movtext and ass decoders all convert their markup
/// into ASS, so one parser downstream handles every text format. The bitmap
/// decoders — pgssub, dvdsub, dvbsub — give paletted pictures, turned into
/// premultiplied BGRA here, once per event.
public final class FFmpegSubtitleDecoder: @unchecked Sendable {
  private var context: UnsafeMutablePointer<AVCodecContext>?

  /// The ASS header the decoder works against: the track's own for ASS, one
  /// FFmpeg generates for everything else. Carries the styles.
  public let subtitleHeader: String
  /// PGS, DVD, DVB: each event replaces the whole picture. Text formats may
  /// overlap instead. FFmpeg's codec description says which a codec is.
  public let isBitmap: Bool

  /// Only `FFmpegDemuxer` creates these; the parameters come from the container.
  internal init(
    parameters: UnsafeMutablePointer<AVCodecParameters>,
    timeBaseNum: Int32,
    timeBaseDen: Int32
  ) throws {
    guard parameters.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
      throw FFmpegDecoderError.notASubtitleStream
    }
    guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
      let name = avcodec_get_name(parameters.pointee.codec_id)
        .map { String(cString: $0) } ?? "unknown"
      throw FFmpegDecoderError.decoderNotFound(name)
    }
    guard let context = avcodec_alloc_context3(codec) else {
      throw FFmpegDecoderError.contextAllocationFailed
    }

    let copyResult = avcodec_parameters_to_context(context, parameters)
    if copyResult < 0 {
      var mutable: UnsafeMutablePointer<AVCodecContext>? = context
      avcodec_free_context(&mutable)
      throw FFmpegDecoderError.openFailed(copyResult)
    }
    // Without a packet time base FFmpeg cannot turn the packet duration into
    // an end time, and every SRT cue would lose its end.
    context.pointee.pkt_timebase = AVRational(num: timeBaseNum, den: timeBaseDen)

    let openResult = avcodec_open2(context, codec, nil)
    if openResult < 0 {
      var mutable: UnsafeMutablePointer<AVCodecContext>? = context
      avcodec_free_context(&mutable)
      throw FFmpegDecoderError.openFailed(openResult)
    }

    self.context = context
    let properties = avcodec_descriptor_get(parameters.pointee.codec_id)?.pointee.props ?? 0
    isBitmap = properties & AV_CODEC_PROP_BITMAP_SUB != 0
    if let header = context.pointee.subtitle_header, context.pointee.subtitle_header_size > 0 {
      subtitleHeader = String(
        decoding: UnsafeBufferPointer(start: header, count: Int(context.pointee.subtitle_header_size)),
        as: UTF8.self)
    } else {
      subtitleHeader = ""
    }
  }

  deinit {
    close()
  }

  /// Decodes one packet. Usually one subtitle, sometimes none.
  ///
  /// The packet's duration matters: for SRT it is the only place the end time
  /// is written.
  public func decode(_ packet: FFmpegPacket) throws -> [FFmpegSubtitle] {
    guard let context, !packet.data.isEmpty else { return [] }
    guard let avPacket = av_packet_alloc() else {
      throw FFmpegDecoderError.packetAllocationFailed
    }
    defer {
      var mutable: UnsafeMutablePointer<AVPacket>? = avPacket
      av_packet_free(&mutable)
    }
    let size = Int32(packet.data.count)
    if av_new_packet(avPacket, size) < 0 {
      throw FFmpegDecoderError.packetAllocationFailed
    }
    packet.data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress, let target = avPacket.pointee.data else { return }
      memcpy(target, base, Int(size))
    }
    avPacket.pointee.pts = packet.pts
    avPacket.pointee.dts = packet.dts
    avPacket.pointee.duration = packet.duration
    if packet.timeBaseNum > 0, packet.timeBaseDen > 0 {
      context.pointee.pkt_timebase = AVRational(num: packet.timeBaseNum, den: packet.timeBaseDen)
    }

    var subtitle = AVSubtitle()
    var gotSubtitle: Int32 = 0
    let result = avcodec_decode_subtitle2(context, &subtitle, &gotSubtitle, avPacket)
    if result < 0 {
      throw FFmpegDecoderError.sendFailed(result)
    }
    guard gotSubtitle != 0 else { return [] }
    defer { avsubtitle_free(&subtitle) }

    // FFmpeg reports display times relative to the subtitle's pts, which is in
    // microseconds once a packet time base is set.
    guard subtitle.pts != FFmpegPacket.noTimestamp else { return [] }
    let start = subtitle.pts + Int64(subtitle.start_display_time) * 1000
    // The largest value means "until the next event"; PGS uses it throughout.
    let isOpenEnded = subtitle.end_display_time == 0 || subtitle.end_display_time == UInt32.max
    let end: Int64? = isOpenEnded ? nil : subtitle.pts + Int64(subtitle.end_display_time) * 1000

    var lines: [String] = []
    var bitmaps: [FFmpegSubtitleBitmap] = []
    for index in 0..<Int(subtitle.num_rects) {
      guard let rect = subtitle.rects[index] else { continue }
      switch rect.pointee.type {
      case SUBTITLE_ASS:
        if let ass = rect.pointee.ass { lines.append(String(cString: ass)) }
      case SUBTITLE_BITMAP:
        if let bitmap = Self.bitmap(from: rect.pointee) { bitmaps.append(bitmap) }
      default:
        continue
      }
    }
    return [
      FFmpegSubtitle(
        startMicroseconds: start, endMicroseconds: end, assLines: lines, bitmaps: bitmaps,
        canvasWidth: Int(context.pointee.width), canvasHeight: Int(context.pointee.height)),
    ]
  }

  /// A paletted rectangle as premultiplied BGRA. Nil when it holds no picture —
  /// a damaged stream leaves an empty rectangle rather than failing.
  private static func bitmap(from rect: AVSubtitleRect) -> FFmpegSubtitleBitmap? {
    let width = Int(rect.w)
    let height = Int(rect.h)
    let stride = Int(rect.linesize.0)
    guard width > 0, height > 0, stride >= width,
          let indices = rect.data.0, let paletteBytes = rect.data.1 else { return nil }

    // Indices past the palette's colours stay transparent.
    var palette = [[UInt8]](repeating: [0, 0, 0, 0], count: 256)
    let colors = min(max(Int(rect.nb_colors), 0), 256)
    paletteBytes.withMemoryRebound(to: UInt32.self, capacity: colors) { entries in
      for index in 0..<colors { palette[index] = premultipliedBGRA(entries[index]) }
    }

    var pixels = Data(count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
      guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      for row in 0..<height {
        for column in 0..<width {
          let color = palette[Int(indices[row * stride + column])]
          let offset = (row * width + column) * 4
          out[offset] = color[0]
          out[offset + 1] = color[1]
          out[offset + 2] = color[2]
          out[offset + 3] = color[3]
        }
      }
    }
    return FFmpegSubtitleBitmap(
      x: Int(rect.x), y: Int(rect.y), width: width, height: height, pixels: pixels)
  }

  /// One palette entry — FFmpeg's `0xAARRGGBB`, straight alpha — as
  /// premultiplied B, G, R, A.
  internal static func premultipliedBGRA(_ entry: UInt32) -> [UInt8] {
    let alpha = entry >> 24
    func scaled(_ shift: UInt32) -> UInt8 {
      UInt8(((entry >> shift & 0xFF) * alpha + 127) / 255)
    }
    return [scaled(0), scaled(8), scaled(16), UInt8(alpha)]
  }

  /// Clears decoder state after a seek.
  public func flush() {
    guard let context else { return }
    avcodec_flush_buffers(context)
  }

  /// Releases the decoder. Safe to call more than once.
  public func close() {
    guard context != nil else { return }
    var mutable = context
    context = nil
    avcodec_free_context(&mutable)
  }
}
