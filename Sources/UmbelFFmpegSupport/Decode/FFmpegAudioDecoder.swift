import FFmpeg
import Foundation

public enum FFmpegDecoderError: Error, Sendable {
  case notAnAudioStream
  case notAVideoStream
  case notASubtitleStream
  case decoderNotFound(String)
  case contextAllocationFailed
  case openFailed(Int32)
  /// Memory for a packet could not be had.
  case packetAllocationFailed
  /// The decoder refused the packet; the code is FFmpeg's. Decoders report
  /// damaged input with codes of their own, not only AVERROR_INVALIDDATA.
  /// EAGAIN means bounded backpressure recovery failed, not damaged input.
  case sendFailed(Int32)
  case receiveFailed(Int32)
  case unsupportedSampleFormat(Int32)
  case unsupportedPixelFormat(Int32)
}

/// Audio decoding: compressed packets in, normalised planar float32 out.
///
/// Made by `FFmpegDemuxer`: the codec parameters (extradata included) come
/// from the container, and stay inside this module rather than cross it.
public final class FFmpegAudioDecoder: @unchecked Sendable {
  private var context: UnsafeMutablePointer<AVCodecContext>?
  internal var operations = FFmpegCodecOperations()
  private let pump = FFmpegDecodePump<FFmpegAudioFrame>()
  private var resampler: FFmpegResampler?
  /// Frames given up on when they were due: the decoder reported them
  /// failed, and they were skipped.
  public private(set) var damagedFrameCount = 0

  /// Output frames are in **the input packets' time base**: the decoder only
  /// passes pts through, and there is no reason to read it in another. The
  /// stream's time base given at construction is only a fallback before any
  /// packet arrives.
  private var currentTimeBaseNum: Int32
  private var currentTimeBaseDen: Int32

  public private(set) var sampleRate: Int32
  public private(set) var channelCount: Int32
  /// The parameters it was made from, when made from a copy of them.
  public internal(set) var parameters: FFmpegCodecParameters?

  /// The format frames come out in; nil for each frame's own. See
  /// `convertOutput(toSampleRate:channelCount:)`.
  public private(set) var outputSampleRate: Int32?
  public private(set) var outputChannelCount: Int32?
  /// What the resampler was made for. A frame in another format gets a new
  /// one: handed another channel count, the old one would read planes that
  /// are not there.
  private var resamplerInput: (format: FFmpegResampler.InputFormat, channels: Int, rate: Int32)?

  /// Puts every frame out in this format from now on, converting the rate
  /// and the channels where the content's differ — as they may midway,
  /// when a stream splices in content encoded otherwise.
  public func convertOutput(toSampleRate sampleRate: Int32, channelCount: Int32) {
    outputSampleRate = sampleRate
    outputChannelCount = channelCount
    dropResampler()
  }

  private func dropResampler() {
    resampler?.release()
    resampler = nil
    resamplerInput = nil
  }

  /// For `FFmpegDemuxer` only. The parameters come from the container's
  /// stream description.
  internal init(
    parameters: UnsafeMutablePointer<AVCodecParameters>,
    timeBaseNum: Int32,
    timeBaseDen: Int32
  ) throws {
    guard parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
      throw FFmpegDecoderError.notAnAudioStream
    }
    self.currentTimeBaseNum = timeBaseNum
    self.currentTimeBaseDen = timeBaseDen

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

    // Without the packets' time base, FFmpeg cannot move a frame's stamp on
    // by the samples it drops from its start, the codec's delay.
    if timeBaseNum > 0, timeBaseDen > 0 {
      context.pointee.pkt_timebase = AVRational(num: timeBaseNum, den: timeBaseDen)
    }

    let openResult = avcodec_open2(context, codec, nil)
    if openResult < 0 {
      var mutable: UnsafeMutablePointer<AVCodecContext>? = context
      avcodec_free_context(&mutable)
      throw FFmpegDecoderError.openFailed(openResult)
    }

    self.context = context
    self.sampleRate = context.pointee.sample_rate
    self.channelCount = context.pointee.ch_layout.nb_channels
  }

  deinit {
    close()
  }

  /// Sends a packet in and takes out every frame it yields. May be none, while
  /// the decoder gathers data.
  public func decode(_ packet: FFmpegPacket) throws -> [FFmpegAudioFrame] {
    guard let context else { return [] }
    guard let avPacket = av_packet_alloc() else {
      throw FFmpegDecoderError.packetAllocationFailed
    }
    defer {
      var mutable: UnsafeMutablePointer<AVPacket>? = avPacket
      av_packet_free(&mutable)
    }

    if !packet.data.isEmpty {
      let size = Int32(packet.data.count)
      if av_new_packet(avPacket, size) < 0 {
        throw FFmpegDecoderError.packetAllocationFailed
      }
      packet.data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress, let target = avPacket.pointee.data else { return }
        memcpy(target, base, Int(size))
      }
    }
    avPacket.pointee.pts = packet.pts
    avPacket.pointee.dts = packet.dts

    // Note the packet's time base; output frames are read in the same one.
    if packet.timeBaseNum > 0, packet.timeBaseDen > 0 {
      currentTimeBaseNum = packet.timeBaseNum
      currentTimeBaseDen = packet.timeBaseDen
      context.pointee.pkt_timebase = AVRational(num: packet.timeBaseNum, den: packet.timeBaseDen)
    }

    return try pump.decode(
      context: context, packet: UnsafePointer(avPacket), operations: operations,
      onDamagedFrame: { self.damagedFrameCount += 1 }, convert: convert)
  }

  /// Clears the decoder after a seek.
  public func flush() {
    pump.reset()
    guard let context else { return }
    avcodec_flush_buffers(context)
    // Converting the rate, the resampler holds a few milliseconds back;
    // after a seek they belong to where playback was.
    dropResampler()
  }

  /// Releases what is held beneath. Can be called again.
  public func close() {
    pump.reset()
    resampler?.release()
    resampler = nil
    guard context != nil else { return }
    var mutable = context
    context = nil
    avcodec_free_context(&mutable)
  }

  private func convert(_ frame: UnsafeMutablePointer<AVFrame>) throws -> FFmpegAudioFrame {
    let frameCount = Int(frame.pointee.nb_samples)
    let channels = Int(frame.pointee.ch_layout.nb_channels)

    guard let inputFormat = FFmpegResampler.InputFormat.from(rawValue: frame.pointee.format) else {
      throw FFmpegDecoderError.unsupportedSampleFormat(frame.pointee.format)
    }

    let rate = frame.pointee.sample_rate
    let outChannels = Int(outputChannelCount ?? Int32(channels))
    let outRate = outputSampleRate ?? rate
    let madeFor = resamplerInput
    if resampler == nil || madeFor?.format != inputFormat || madeFor?.channels != channels
      || madeFor?.rate != rate {
      resampler?.release()
      resampler = try FFmpegResampler(
        inputFormat: inputFormat, inputChannelCount: channels, inputSampleRate: rate,
        outputChannelCount: outChannels, outputSampleRate: outRate)
      resamplerInput = (inputFormat, channels, rate)
    }

    // Planar formats have a plane per channel; interleaved ones a single one.
    let planeCount = inputFormat.isPlanarLayout ? channels : 1
    var planes: [UnsafeMutableRawPointer] = []
    planes.reserveCapacity(planeCount)
    for index in 0..<planeCount {
      guard let plane = frame.pointee.extended_data[index] else { continue }
      planes.append(UnsafeMutableRawPointer(plane))
    }

    let samples = try resampler?.convert(planes: planes, frameCount: frameCount) ?? []
    return FFmpegAudioFrame(
      samples: samples,
      frameCount: samples.count / max(outChannels, 1),
      channelCount: outChannels,
      sampleRate: outRate,
      pts: frame.pointee.pts,
      timeBaseNum: currentTimeBaseNum,
      timeBaseDen: currentTimeBaseDen
    )
  }
}
