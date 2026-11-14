import CoreVideo
import FFmpeg
import Foundation

/// Video decoding: compressed packets in, biplanar `CVPixelBuffer`s out.
///
/// Both paths give the same form. Hardware decoding hands over a buffer
/// (hidden in the frame's fourth data pointer); software decoding copies the
/// planes into a buffer from a pool — the price of one form, paid on the
/// fallback path only.
public final class FFmpegVideoDecoder: @unchecked Sendable {
  private var context: UnsafeMutablePointer<AVCodecContext>?
  internal var operations = FFmpegCodecOperations()
  private let pump = FFmpegDecodePump<FFmpegVideoFrame>()
  private let pixelConverter = VideoPixelBufferConverter()
  private var conversionReason: String?
  private var parameterSetOrder: HEVCParameterSetOrder?
  /// A copy of the stream's parameters, kept while it is not yet known whether
  /// the hardware takes the stream; see `decode(_:)`.
  private var softwareFallbackParameters: UnsafeMutablePointer<AVCodecParameters>?

  /// What the container says of the pixels' shape; 0/1 when it says nothing.
  /// It wins over the bitstream's, as FFmpeg's own guess has it.
  private let containerAspect: AVRational
  /// What the stream's display matrix says of the picture's turn, in
  /// clockwise degrees; 0 when it says nothing.
  private let containerRotation: Int32
  /// The codec's name, for what depends on how it delivers fields.
  private let codecName: String

  /// Output frames are in **the input packets' time base**; the stream's time
  /// base given at construction is only a fallback.
  private var currentTimeBaseNum: Int32
  private var currentTimeBaseDen: Int32

  public private(set) var isHardwareAccelerated = false
  /// Frames given up on as damaged when they were due. With several decoding
  /// threads a damaged packet is reported later than when it was sent: when
  /// a later packet is sent — the send fails — or here, depending on when
  /// its thread finished.
  public private(set) var damagedFrameCount = 0
  public private(set) var width: Int32 = 0
  /// The parameters it was made from, when made from a copy of them.
  public internal(set) var parameters: FFmpegCodecParameters?
  /// Whether it was asked to decode in hardware where it can; a decoder made
  /// again is asked the same.
  public let prefersHardware: Bool
  /// The threads software decoding was asked to run on; 0, as many as
  /// FFmpeg finds the machine suits. A decoder made again is asked the same.
  public let requestedSoftwareThreads: Int32
  public private(set) var height: Int32 = 0

  /// For `FFmpegDemuxer` only. The parameters come from the container's
  /// stream description.
  internal init(
    parameters: UnsafeMutablePointer<AVCodecParameters>,
    timeBaseNum: Int32,
    timeBaseDen: Int32,
    containerAspect: AVRational,
    containerRotation: Int32 = 0,
    preferHardware: Bool,
    softwareThreadCount: Int32 = 0
  ) throws {
    guard parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO else {
      throw FFmpegDecoderError.notAVideoStream
    }
    self.containerAspect = containerAspect
    self.containerRotation = containerRotation
    self.codecName = avcodec_get_name(parameters.pointee.codec_id).map { String(cString: $0) } ?? ""
    self.prefersHardware = preferHardware
    self.requestedSoftwareThreads = softwareThreadCount
    self.currentTimeBaseNum = timeBaseNum
    self.currentTimeBaseDen = timeBaseDen

    var deviceContext: UnsafeMutablePointer<AVBufferRef>?
    if preferHardware, HardwareDecodeSupport.canDecode(parameters) {
      let status = av_hwdevice_ctx_create(
        &deviceContext, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
      if status < 0 { av_buffer_unref(&deviceContext) }
    }
    // The codec context takes its own reference below, including on an
    // initialization failure. No device reference is owned by this wrapper.
    defer { av_buffer_unref(&deviceContext) }
    let context = try Self.openContext(
      parameters, device: deviceContext, softwareThreadCount: softwareThreadCount)
    self.isHardwareAccelerated = deviceContext != nil
    // Whether the hardware takes the stream is settled when its headers are
    // first read; until then, what is needed to go on without it is kept.
    if deviceContext != nil {
      softwareFallbackParameters = avcodec_parameters_alloc()
      if let copy = softwareFallbackParameters, avcodec_parameters_copy(copy, parameters) < 0 {
        avcodec_parameters_free(&softwareFallbackParameters)
      }
    }

    self.context = context
    self.width = context.pointee.width
    self.height = context.pointee.height
    if isHardwareAccelerated, parameters.pointee.codec_id == AV_CODEC_ID_HEVC {
      let extra = parameters.pointee.extradata
      let lengthSize = parameters.pointee.extradata_size >= 22 && extra?[0] == 1
        ? extra.map { Int($0[21] & 3) + 1 } : nil
      parameterSetOrder = HEVCParameterSetOrder(lengthSize: lengthSize)
    }
  }

  deinit {
    close()
  }

  /// A codec context opened for the parameters: with the hardware device, or
  /// without, in software.
  private static func openContext(
    _ parameters: UnsafeMutablePointer<AVCodecParameters>,
    device deviceContext: UnsafeMutablePointer<AVBufferRef>?,
    softwareThreadCount: Int32
  ) throws -> UnsafeMutablePointer<AVCodecContext> {
    // FFmpeg's default AV1 decoder becomes libdav1d when it is present.
    // Explicit selection keeps VideoToolbox on supported hardware; the
    // native "av1" decoder has no software implementation to fall back to.
    let selected = parameters.pointee.codec_id == AV_CODEC_ID_AV1
      ? avcodec_find_decoder_by_name(deviceContext == nil ? "libdav1d" : "av1")
      : avcodec_find_decoder(parameters.pointee.codec_id)
    guard let codec = selected else {
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

    if let deviceContext {
      context.pointee.hw_device_ctx = av_buffer_ref(deviceContext)
    }

    // Software decoding uses every core unless told how many, as the ffmpeg
    // tool does by default; left at FFmpeg's default of one thread, it could
    // not keep up with high resolutions. Hardware decoding stays on one: the
    // hardware does the work, and each extra frame thread would hold more
    // surfaces.
    if deviceContext == nil {
      context.pointee.thread_count = softwareThreadCount
    }

    let openResult = avcodec_open2(context, codec, nil)
    if openResult < 0 {
      var mutable: UnsafeMutablePointer<AVCodecContext>? = context
      avcodec_free_context(&mutable)
      throw FFmpegDecoderError.openFailed(openResult)
    }
    return context
  }

  /// Whether an interlaced frame of this codec is the two fields woven into
  /// one picture, as H.264, MPEG-2 and most others pair them. HEVC and VVC
  /// do not: a field-coded stream of theirs gives one half-height picture per
  /// field, each flagged interlaced, and such a picture is no woven frame.
  internal static func deliversWovenFields(codecName: String) -> Bool {
    codecName != "hevc" && codecName != "vvc"
  }

  /// What a frame is reported as: interlaced where the decoder flagged it
  /// and the codec's frames are woven pairs of fields.
  internal static func reportsInterlaced(flagged: Bool, codecName: String) -> Bool {
    flagged && deliversWovenFields(codecName: codecName)
  }

  /// Threads decoding runs on, as settled when the decoder opened. 0 where
  /// the codec's own library picks them (AV1 in software, asked for none).
  public var threadCount: Int32 { context?.pointee.thread_count ?? 0 }

  /// Leaves frames no other frame refers to undecoded, from the next packet
  /// on — for decoding that has fallen behind: skipping them costs the
  /// frames that are decoded nothing.
  public var skipsNonReferenceFrames: Bool {
    get { context?.pointee.skip_frame == AVDISCARD_NONREF }
    set { context?.pointee.skip_frame = newValue ? AVDISCARD_NONREF : AVDISCARD_DEFAULT }
  }

  /// Sends a packet in and takes out every frame it yields. May be none, while
  /// the decoder gathers data.
  ///
  /// Hardware is chosen for a stream before it has been read, and
  /// VideoToolbox may refuse it when its headers are: FFmpeg then goes on in
  /// software, on the one thread the context was opened with for hardware.
  /// When the first headers show that, the decoder is opened again as a
  /// software decoder and given the packet again. Nothing was shown from the
  /// first, which has seen no more than this packet, and nothing is lost.
  public func decode(_ packet: FFmpegPacket) throws -> [FFmpegVideoFrame] {
    guard let context else { return [] }
    let frames = try send(packet, data: parameterSetOrder?.prepare(packet.data) ?? packet.data, to: context)
    guard softwareFallbackParameters != nil, context.pointee.pix_fmt != AV_PIX_FMT_NONE else { return frames }
    // The headers have been read.
    if context.pointee.pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX {
      avcodec_parameters_free(&softwareFallbackParameters)
      return frames
    }
    try reopenInSoftware()
    guard let reopened = self.context else { return [] }
    return try send(packet, data: packet.data, to: reopened)
  }

  private func reopenInSoftware() throws {
    guard let parameters = softwareFallbackParameters else { return }
    let replacement = try Self.openContext(
      parameters, device: nil, softwareThreadCount: requestedSoftwareThreads)
    var old = context
    context = replacement
    avcodec_free_context(&old)
    avcodec_parameters_free(&softwareFallbackParameters)
    isHardwareAccelerated = false
    parameterSetOrder = nil
    pump.reset()
  }

  private func send(
    _ packet: FFmpegPacket, data: Data, to context: UnsafeMutablePointer<AVCodecContext>
  ) throws -> [FFmpegVideoFrame] {
    guard let avPacket = av_packet_alloc() else {
      throw FFmpegDecoderError.packetAllocationFailed
    }
    defer {
      var mutable: UnsafeMutablePointer<AVPacket>? = avPacket
      av_packet_free(&mutable)
    }

    if !data.isEmpty {
      let size = Int32(data.count)
      if av_new_packet(avPacket, size) < 0 {
        throw FFmpegDecoderError.packetAllocationFailed
      }
      data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress, let target = avPacket.pointee.data else { return }
        memcpy(target, base, Int(size))
      }
    }
    avPacket.pointee.pts = packet.pts
    avPacket.pointee.dts = packet.dts
    // Its frame takes the duration from it: what shows a field's picture
    // half a frame after the other.
    avPacket.pointee.duration = packet.duration
    if packet.timeBaseNum > 0, packet.timeBaseDen > 0 {
      currentTimeBaseNum = packet.timeBaseNum
      currentTimeBaseDen = packet.timeBaseDen
    }

    return try pump.decode(
      context: context, packet: UnsafePointer(avPacket), operations: operations,
      onDamagedFrame: { self.damagedFrameCount += 1 }, convert: convert)
  }

  /// Clears the decoder after a seek.
  public func flush() {
    pump.reset()
    guard let context else { return }
    parameterSetOrder?.reset()
    avcodec_flush_buffers(context)
  }

  /// Releases what is held beneath. Can be called again.
  public func close() {
    pump.reset()
    pixelConverter.reset()
    avcodec_parameters_free(&softwareFallbackParameters)
    guard context != nil else { return }
    var mutable = context
    context = nil
    avcodec_free_context(&mutable)
  }

  private func convert(
    _ frame: UnsafeMutablePointer<AVFrame>
  ) throws -> FFmpegVideoFrame? {
    let frameWidth = frame.pointee.width
    let frameHeight = frame.pointee.height
    conversionReason = nil

    let buffer: CVPixelBuffer
    let hardware: Bool

    if frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
       let raw = frame.pointee.data.3 {
      // Hardware: the buffer is in the fourth data pointer; used as it is,
      // no copy.
      buffer = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw))
        .takeUnretainedValue()
      hardware = true
    } else {
      // Software: copied into a buffer from the pool, for one form of frame.
      buffer = try copyIntoPixelBuffer(frame, width: frameWidth, height: frameHeight)
      hardware = false
    }

    // The bitstream's shape can change mid-stream — a broadcast switching
    // between 4:3 and 16:9 — so it is read per frame.
    let aspect = containerAspect.num > 0 && containerAspect.den > 0
      ? containerAspect : frame.pointee.sample_aspect_ratio
    return FFmpegVideoFrame(
      pixelBuffer: buffer,
      width: frameWidth,
      height: frameHeight,
      pts: frame.pointee.pts,
      timeBaseNum: currentTimeBaseNum,
      timeBaseDen: currentTimeBaseDen,
      colorspace: VideoPixelBufferConverter.isRGBBuffer(buffer) ? 0
        : FFmpegVideoFormat(pixelFormatCode: frame.pointee.format)?.isRGB == true ? 1
        : Int32(frame.pointee.colorspace.rawValue),
      colorRange: CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
        || CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
        ? 1 : VideoPixelBufferConverter.isFullRangeBuffer(buffer) ? 2 : Int32(frame.pointee.color_range.rawValue),
      colorTransfer: Int32(frame.pointee.color_trc.rawValue),
      colorPrimaries: Int32(frame.pointee.color_primaries.rawValue),
      hdr: FFmpegHDRMetadata(frame: frame),
      sampleAspectNum: aspect.num,
      sampleAspectDen: aspect.den,
      rotation: containerRotation,
      isInterlaced: Self.reportsInterlaced(
        flagged: frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0, codecName: codecName),
      topFieldFirst: frame.pointee.flags & AV_FRAME_FLAG_TOP_FIELD_FIRST != 0,
      duration: frame.pointee.duration,
      frameRateNum: context?.pointee.framerate.num ?? 0,
      frameRateDen: context?.pointee.framerate.den ?? 1,
      wasHardwareDecoded: hardware,
      sourceFormat: FFmpegVideoFormat(pixelFormatCode: hardware
        ? (context?.pointee.sw_pix_fmt.rawValue ?? AV_PIX_FMT_NONE.rawValue) : frame.pointee.format),
      hasDynamicMetadata: av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER) != nil
        || av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA) != nil,
      conversionReason: conversionReason, chromaLocationCode: Int32(frame.pointee.chroma_location.rawValue)
    )
  }

  internal func copyIntoPixelBuffer(
    _ frame: UnsafeMutablePointer<AVFrame>, width: Int32, height: Int32
  ) throws -> CVPixelBuffer {
    let converted = try pixelConverter.convert(frame, width: width, height: height, codecName: codecName)
    conversionReason = converted.reason
    return converted.buffer
  }
}
