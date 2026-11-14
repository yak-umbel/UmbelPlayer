import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Turns compressed packets into the domain's PCM frames.
///
/// An actor to serialise access to the decoder, whose context is not thread
/// safe. No dedicated thread is needed: decoding is plain CPU work that does
/// not block the way I/O callbacks do, a few tens of microseconds a frame.
internal actor AudioDecodeSession {
  private var decoder: FFmpegAudioDecoder
  private var isClosed = false
  /// Decoders made again for packets with other parameters.
  internal private(set) var rebuildCount = 0
  /// Whether it has been drained. Drained, the decoder is at its end and a
  /// packet sent now is reported as an error; "no second batch after a
  /// drain" is this layer's rule, not a reason to loosen the error check
  /// beneath.
  private var hasDrained = false
  /// Packets the decoder rejected as damaged, and skipped. See `decode(_:)`.
  private(set) var rejectedPacketCount = 0
  /// Frames out of the decoders of this track, and those they failed when
  /// due, the decoder before a rebuild's included.
  private var decodedFrameCount = 0
  private var damagedBefore = 0
  internal var decodingCounts: UmbelDecodingCounts {
    UmbelDecodingCounts(
      decodedFrames: decodedFrameCount, rejectedPackets: rejectedPacketCount,
      damagedFrames: damagedBefore + decoder.damagedFrameCount)
  }

  internal init(decoder: FFmpegAudioDecoder) {
    self.decoder = decoder
  }

  internal func decode(_ packet: DemuxPacket) throws -> [AudioFrame] {
    guard !isClosed else { return [] }
    let held = try adoptParameters(of: packet)
    // The domain's times are CMTime; beneath, integer ticks and a time
    // base. Packed in microseconds throughout; frame(from:) converts back
    // from the time base the decoder fills in.
    let raw = FFmpegPacket(
      streamIndex: packet.trackID.rawValue,
      data: packet.data,
      pts: Self.microseconds(from: packet.presentationTime),
      dts: Self.microseconds(from: packet.decodeTime),
      duration: 0,
      timeBaseNum: 1,
      timeBaseDen: 1_000_000,
      isKeyframe: packet.isKeyframe
    )
    do {
      let decoded = try decoder.decode(raw)
      decodedFrameCount += decoded.count
      return held + decoded.map(Self.frame(from:))
    } catch FFmpegDecoderError.sendFailed(let code) {
      guard code != FFmpegErrorCode.tryAgainRaw,
            FFmpegErrorCode.classify(code) != .endOfFile else {
        throw UmbelError.decoderFailure(codec: "audio", code: code)
      }
      // The decoder refused the packet: damaged, or a partial one a file
      // cut mid-frame starts with. Skipped and counted, as FFmpeg's own tools
      // skip it — failing the film over one packet would be the odd one out.
      // End of file means packets arrived after a drain; unresolved
      // backpressure means codec recovery failed. Neither is damaged input.
      rejectedPacketCount += 1
      return []
    } catch FFmpegDecoderError.receiveFailed(let code) {
      throw UmbelError.decoderFailure(codec: "audio", code: code)
    } catch {
      throw UmbelError.decoderFailure(codec: "audio", code: 0)
    }
  }

  /// The frames still held in the decoder. Called at the end of the content.
  ///
  /// An empty packet is the signal to drain. Drained, the decoder is at its
  /// end, and needs `flush()` before it takes packets again.
  internal func drain() throws -> [AudioFrame] {
    guard !isClosed, !hasDrained else { return [] }
    hasDrained = true
    do {
      let decoded = try decoder.decode(Self.drainSignal)
      decodedFrameCount += decoded.count
      return decoded.map(Self.frame(from:))
    } catch {
      throw UmbelError.decoderFailure(codec: "audio", code: 0)
    }
  }

  /// A packet decoding with other parameters than the decoder was made for —
  /// a playlist moved on to content encoded otherwise — gets a decoder made
  /// for them, putting sound out in the same format as the one before. What
  /// the old one still holds is drained first and handed on.
  private func adoptParameters(of packet: DemuxPacket) throws -> [AudioFrame] {
    guard let parameters = packet.decoderParameters, parameters !== decoder.parameters else {
      return []
    }
    let held = (try? decoder.decode(Self.drainSignal)) ?? []
    let replacement: FFmpegAudioDecoder
    do {
      replacement = try parameters.makeAudioDecoder()
    } catch {
      throw UmbelError.decoderFailure(codec: "audio", code: 0)
    }
    if let rate = decoder.outputSampleRate, let channels = decoder.outputChannelCount {
      replacement.convertOutput(toSampleRate: rate, channelCount: channels)
    }
    damagedBefore += decoder.damagedFrameCount
    decoder.close()
    decoder = replacement
    hasDrained = false
    rebuildCount += 1
    decodedFrameCount += held.count
    return held.map(Self.frame(from:))
  }

  /// The empty packet. A time base of 0 means "the last real packet's".
  private static let drainSignal = FFmpegPacket(
    streamIndex: 0, data: Data(),
    pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
    duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false)

  /// Clears the decoder after a seek, so nothing from before leaks into the
  /// new position.
  internal func flush() {
    guard !isClosed else { return }
    // A drained decoder is usable again from here.
    hasDrained = false
    decoder.flush()
  }

  internal func close() {
    guard !isClosed else { return }
    isClosed = true
    decoder.close()
  }

  // ── Conversion ──────────────────────────────────────

  private static func microseconds(from time: CMTime) -> Int64 {
    guard time.isValid, !time.isIndefinite else { return FFmpegPacket.noTimestamp }
    return Int64(time.seconds * 1_000_000)
  }

  private static func frame(from raw: FFmpegAudioFrame) -> AudioFrame {
    AudioFrame(
      presentationTime: TrackMapping.time(
        ticks: raw.pts, num: raw.timeBaseNum, den: raw.timeBaseDen),
      sampleRate: Double(raw.sampleRate),
      channelCount: raw.channelCount,
      frameCount: raw.frameCount,
      samples: raw.samples
    )
  }
}
