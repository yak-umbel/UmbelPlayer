import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Decoder state owned by exactly one session. The synchronous owner uses
/// actor isolation; the asynchronous owner confines every access to its queue.
/// Sendability permits transferring ownership, never concurrent engine calls.
internal final class VideoDecodeEngine: VideoDecodingEngine, @unchecked Sendable {
  private var decoder: FFmpegVideoDecoder
  private var isClosed = false
  /// Decoders made again for packets with other parameters.
  internal private(set) var rebuildCount = 0
  /// Whether it has been drained. Drained, the decoder is at its end and a
  /// packet sent now is reported as an error; "no second batch after a
  /// drain" is this layer's rule, not a reason to loosen the error check
  /// beneath.
  private var hasDrained = false
  /// Packets the decoder rejected as damaged, and skipped. See `decode(_:)`.
  /// Decoding on several threads, a packet's damage is reported later, on
  /// sending another or when its frame was due; this counts both.
  internal var rejectedPacketCount: Int { refusedOnSending + damagedFrameCount }
  private var refusedOnSending = 0
  /// Frames failed when they were due, by this decoder and those before it.
  private var damagedFrameCount: Int { damagedBefore + decoder.damagedFrameCount }
  private var damagedBefore = 0
  /// Frames out of the decoder; those it skipped are not among them.
  internal private(set) var decodedFrameCount = 0
  internal var decodingCounts: UmbelDecodingCounts? {
    UmbelDecodingCounts(
      decodedFrames: decodedFrameCount, rejectedPackets: refusedOnSending, damagedFrames: damagedFrameCount)
  }
  /// Falling behind; see `VideoCatchUp`.
  private var skipsToCatchUp = false

  /// A DV base layer's colour, for frames that declare none.
  private var baseLayer: UmbelDVBaseLayer?
  /// Makes interlaced frames progressive on the way out; nil, none.
  private let deinterlacer: VideoDeinterlacer?

  internal init(
    decoder: FFmpegVideoDecoder, baseLayer: UmbelDVBaseLayer? = nil, deinterlacer: VideoDeinterlacer? = nil
  ) {
    self.decoder = decoder
    self.baseLayer = baseLayer
    self.deinterlacer = deinterlacer
  }

  internal var isHardwareAccelerated: Bool { decoder.isHardwareAccelerated }

  internal var decoderStatus: UmbelVideoDecoderStatus? {
    decoder.isHardwareAccelerated
      ? .hardware : .software(threads: decoder.threadCount > 0 ? Int(decoder.threadCount) : nil)
  }

  /// `hidden`: its frame will not be shown — it comes before a seek's
  /// target. Such a frame is decoded only if others refer to it: a seek
  /// decodes from the keyframe before its target, and the rest of the way is
  /// never seen.
  internal func decode(_ packet: DemuxPacket, hidden: Bool = false) throws -> [VideoFrame] {
    guard !isClosed else { return [] }
    let held = try adoptParameters(of: packet)
    decoder.skipsNonReferenceFrames = skipsToCatchUp || hidden
    // As for audio: packed in microseconds; the decoder keeps the input
    // packets' time base.
    let raw = FFmpegPacket(
      streamIndex: packet.trackID.rawValue,
      data: packet.data,
      pts: Self.microseconds(from: packet.presentationTime),
      dts: Self.microseconds(from: packet.decodeTime),
      duration: Self.microseconds(duration: packet.duration),
      timeBaseNum: 1,
      timeBaseDen: 1_000_000,
      isKeyframe: packet.isKeyframe
    )
    let decoded: [FFmpegVideoFrame]
    do {
      decoded = try decoder.decode(raw)
    } catch FFmpegDecoderError.sendFailed(let code) {
      guard code != FFmpegErrorCode.tryAgainRaw,
            FFmpegErrorCode.classify(code) != .endOfFile else {
        throw UmbelError.decoderFailure(codec: "video", code: code)
      }
      // Skipped, not fatal: the same rule as for audio.
      refusedOnSending += 1
      return []
    } catch FFmpegDecoderError.receiveFailed(let code) {
      throw UmbelError.decoderFailure(codec: "video", code: code)
    } catch {
      throw UmbelError.decoderFailure(codec: "video", code: 0)
    }
    decodedFrameCount += decoded.count
    return deinterlaced(try held + decoded.map { try Self.frame(from: $0, baseLayer: baseLayer) })
  }

  /// A packet decoding with other parameters than the decoder was made for —
  /// a playlist moved on to content encoded otherwise — gets a decoder made
  /// for them. What the old one still holds is drained first and handed on,
  /// so the last pictures before the change are not lost.
  private func adoptParameters(of packet: DemuxPacket) throws -> [VideoFrame] {
    guard let parameters = packet.decoderParameters, parameters !== decoder.parameters else {
      return []
    }
    let held = (try? decoder.decode(Self.drainSignal)) ?? []
    let previousBaseLayer = baseLayer
    let replacement: FFmpegVideoDecoder
    do {
      replacement = try parameters.makeVideoDecoder(
        preferHardware: decoder.prefersHardware, softwareThreadCount: decoder.requestedSoftwareThreads)
    } catch {
      throw UmbelError.decoderFailure(codec: "video", code: 0)
    }
    damagedBefore += decoder.damagedFrameCount
    decoder.close()
    decoder = replacement
    switch parameters.dovi?.compatibility {
    case 1, 6: baseLayer = .hdr10
    case 4: baseLayer = .hlg
    case 2: baseLayer = .sdr
    default: baseLayer = nil
    }
    hasDrained = false
    rebuildCount += 1
    decodedFrameCount += held.count
    return try held.map { try Self.frame(from: $0, baseLayer: previousBaseLayer) }
  }

  /// A new decoder for the same stream, made as the old one was, the old
  /// one closed: iOS takes the hardware decoder away from an app in the
  /// background, and the old one then fails frames until FFmpeg makes it
  /// again. Called with the stream about to go on from a seek.
  internal func renew() throws {
    // Without the parameters it was made from, it cannot be made again.
    guard !isClosed, let parameters = decoder.parameters else { return }
    let replacement: FFmpegVideoDecoder
    do {
      replacement = try parameters.makeVideoDecoder(
        preferHardware: decoder.prefersHardware, softwareThreadCount: decoder.requestedSoftwareThreads)
    } catch {
      throw UmbelError.decoderFailure(codec: "video", code: 0)
    }
    damagedBefore += decoder.damagedFrameCount
    decoder.close()
    decoder = replacement
    hasDrained = false
    skipsToCatchUp = false
    deinterlacer?.reset()
    rebuildCount += 1
  }

  /// The frames still held in the decoder. Called at the end of the content.
  ///
  /// An empty packet is the signal to drain: no more input is coming, and
  /// the decoder gives up every frame it holds. Drained, it is at its end,
  /// and needs `flush()` before it takes packets again.
  internal func drain() throws -> [VideoFrame] {
    guard !isClosed, !hasDrained else { return [] }
    hasDrained = true
    let decoded: [FFmpegVideoFrame]
    do {
      decoded = try decoder.decode(Self.drainSignal)
    } catch {
      throw UmbelError.decoderFailure(codec: "video", code: 0)
    }
    decodedFrameCount += decoded.count
    return deinterlaced(try decoded.map { try Self.frame(from: $0, baseLayer: baseLayer) })
  }

  /// The empty packet. A time base of 0 means "the last real packet's" —
  /// `decode` updates it only when both parts are above zero, which is what
  /// a drain wants.
  private static let drainSignal = FFmpegPacket(
    streamIndex: 0, data: Data(),
    pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
    duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false)

  /// Clears the decoder after a seek, so nothing from before leaks into the
  /// new position.
  ///
  /// Skipping stops too: whatever was behind belongs to where the stream
  /// was, and the frame a seek lands on may be one nothing refers to.
  internal func flush() {
    guard !isClosed else { return }
    // A drained decoder is usable again from here.
    hasDrained = false
    decoder.flush()
    skipsToCatchUp = false
    deinterlacer?.reset()
  }

  /// Leaves frames no other frame refers to undecoded, from the next packet
  /// on; see `VideoCatchUp`.
  internal func setSkipsNonReference(_ skips: Bool) {
    skipsToCatchUp = skips
  }

  internal var skipsNonReference: Bool { skipsToCatchUp }

  internal func close() {
    guard !isClosed else { return }
    isClosed = true
    decoder.close()
  }

  private func deinterlaced(_ frames: [VideoFrame]) -> [VideoFrame] {
    deinterlacer?.process(frames) ?? frames
  }

  // ── Conversion ──────────────────────────────────────

  private static func microseconds(from time: CMTime) -> Int64 {
    guard time.isValid, !time.isIndefinite else { return FFmpegPacket.noTimestamp }
    return Int64(time.seconds * 1_000_000)
  }

  /// A duration in microseconds; 0, FFmpeg's "not known", when there is none.
  private static func microseconds(duration: CMTime) -> Int64 {
    guard duration.isNumeric, duration.seconds > 0 else { return 0 }
    return Int64(duration.seconds * 1_000_000)
  }

  /// FFmpeg's codes: 2 and 0 are "not declared"; 16 is PQ, 18 HLG, 9 BT.2020.
  private static func frame(
    from raw: FFmpegVideoFrame, baseLayer: UmbelDVBaseLayer?
  ) throws -> VideoFrame {
    var colorspace = raw.colorspace, transfer = raw.colorTransfer, primaries = raw.colorPrimaries
    // A DV base layer that declares no colour is what its configuration
    // names: HDR10 or HLG, on BT.2020.
    if let baseLayer, baseLayer != .sdr, transfer == 2 || transfer == 0 {
      transfer = baseLayer == .hdr10 ? 16 : 18
      if colorspace == 2 || colorspace == 0 { colorspace = 9 }
      if primaries == 2 || primaries == 0 { primaries = 9 }
    }
    var frame = VideoFrame(
      presentationTime: TrackMapping.time(
        ticks: raw.pts, num: raw.timeBaseNum, den: raw.timeBaseDen),
      pixelBuffer: raw.pixelBuffer,
      width: Int(raw.width),
      height: Int(raw.height),
      color: try VideoColorDescription.from(
        colorspace: colorspace, range: raw.colorRange,
        transfer: transfer, primaries: primaries,
        hdr: raw.hdr.map(UmbelHDRMetadata.init(ffmpeg:))),
      pixelAspectRatio: TrackMapping.pixelAspectRatio(
        num: raw.sampleAspectNum, den: raw.sampleAspectDen),
      rotation: UmbelVideoRotation(clockwiseDegrees: raw.rotation)
    )
    if raw.isInterlaced { frame.fieldOrder = raw.topFieldFirst ? .topFirst : .bottomFirst }
    frame.sourcePixelDescription = raw.sourceFormat.map(VideoPixelDescription.init(ffmpeg:))
    frame.hasDynamicMetadata = raw.hasDynamicMetadata
    frame.conversionReason = raw.conversionReason
    frame.chromaLocationCode = raw.chromaLocationCode
    if raw.frameRateNum > 0, raw.frameRateDen > 0 {
      frame.declaredFrameRate = Double(raw.frameRateNum) / Double(raw.frameRateDen)
    }
    if raw.duration > 0 {
      frame.duration = TrackMapping.time(ticks: raw.duration, num: raw.timeBaseNum, den: raw.timeBaseDen)
    }
    return frame
  }
}
