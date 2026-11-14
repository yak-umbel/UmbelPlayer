import FFmpeg
import Foundation

public enum FFmpegDemuxerError: Error, Sendable {
  case openFailed(FFmpegErrorCode)
  case notOpened
  case seekFailed(FFmpegErrorCode)
  case readFailed(FFmpegErrorCode)
  case interrupted
}

/// A demuxer around avformat.
///
/// Every call beneath runs on a dedicated thread: the I/O callbacks beneath
/// block, and need a thread that can safely be blocked.
public final class FFmpegDemuxer: @unchecked Sendable {
  private let thread: SerialWorkerThread
  /// What is read: bytes in order through callbacks, or an address whose
  /// every open goes through the caller.
  private enum Input {
    case bytes(FFmpegIOCallbacks)
    case address(String, FFmpegResourceTable)
  }

  private let input: Input
  private let configuration: FFmpegDemuxerConfiguration
  private let interruptFlag = InterruptFlag()
  private let readAbandonment: ReadAbandonment

  private var formatContext: UnsafeMutablePointer<AVFormatContext>?
  private var ioContext: FFmpegIOContext?
  private let corruptDiscard = CorruptPacketDiscard()

  /// `abandonment`: where a read blocked in the callbacks is given up from
  /// outside; several demuxers that are read one after another can share one.
  public init(
    callbacks: FFmpegIOCallbacks, configuration: FFmpegDemuxerConfiguration,
    abandonment: ReadAbandonment = ReadAbandonment()
  ) {
    self.input = .bytes(callbacks)
    self.configuration = configuration
    self.readAbandonment = abandonment
    self.thread = SerialWorkerThread(name: "umbel.demux")
  }

  /// Reads by address — a playlist FFmpeg's own demuxer reads — opening the
  /// address and everything it names through `opener`.
  public init(
    address: String, opener: @escaping FFmpegResourceOpener,
    configuration: FFmpegDemuxerConfiguration
  ) {
    let flag = interruptFlag
    let abandonment = ReadAbandonment()
    self.readAbandonment = abandonment
    self.input = .address(address, FFmpegResourceTable(
      opener: opener, bufferSize: configuration.ioBufferSize, isInterrupted: { flag.isRaised },
      abandonment: abandonment))
    self.configuration = configuration
    self.thread = SerialWorkerThread(name: "umbel.demux")
  }

  /// Asks the calls beneath, now and from now on, to stop. Used to close a
  /// session stuck in a read.
  public func requestInterrupt() {
    interruptFlag.raise()
  }

  /// Gives up the read the source is being waited on in, if there is one,
  /// and any that begins before `resumeReads()`; the packet being read
  /// fails. Not closing: the source is used again after, from wherever the
  /// next seek puts the demuxer. Callable from any thread.
  public func abandonRead() {
    readAbandonment.abandon()
  }

  /// Reads go on as usual again, after `abandonRead()`.
  public func resumeReads() {
    readAbandonment.resume()
  }

  public func open() async throws {
    try await thread.run { [self] in try openOnThread() }
  }

  public func streams() async -> [FFmpegStreamInfo] {
    (try? await thread.run { [self] in streamsOnThread() }) ?? []
  }

  /// The duration the container declares, in microseconds; nil if unknown.
  public func durationTicks() async -> Int64? {
    guard let value = try? await thread.run({ [self] in durationOnThread() }) else { return nil }
    return value
  }

  /// The earliest timestamp in the file, in microseconds; nil when unknown.
  /// Packet timestamps and seek targets are on the same absolute scale.
  public func startTicks() async -> Int64? {
    guard let value = try? await thread.run({ [self] in startOnThread() }) else { return nil }
    return value
  }

  public func readPacket() async throws -> FFmpegPacket? {
    try await thread.run { [self] in try readPacketOnThread() }
  }

  public func seek(toSeconds seconds: Double) async throws {
    try await thread.run { [self] in try seekOnThread(seconds: seconds) }
  }

  /// Makes an audio decoder for a stream.
  ///
  /// Made here rather than outside because the codec parameters (extradata
  /// included) come from the format context, and stay inside this module
  /// rather than cross the dependency boundary.
  public func makeAudioDecoder(streamIndex: Int32) async throws -> FFmpegAudioDecoder {
    try await thread.run { [self] in try makeAudioDecoderOnThread(streamIndex: streamIndex) }
  }

  /// Makes a video decoder for a stream.
  ///
  /// With `preferHardware`, hardware decoding is tried first; without the
  /// hardware it **falls back** to software rather than failing — which is
  /// what the fallback is for. `softwareThreadCount` is for software
  /// decoding, whether preferred or fallen back to; 0 leaves it to FFmpeg.
  public func makeVideoDecoder(
    streamIndex: Int32,
    preferHardware: Bool = true,
    softwareThreadCount: Int32 = 0
  ) async throws -> FFmpegVideoDecoder {
    try await thread.run { [self] in
      try makeVideoDecoderOnThread(
        streamIndex: streamIndex, preferHardware: preferHardware, softwareThreadCount: softwareThreadCount)
    }
  }

  /// The latest entry in a stream's index at or before `seconds`, in seconds.
  ///
  /// Containers index more than video: MP4 lists every sample of every track,
  /// and Matroska files list subtitle packets too. Nil when the stream has no
  /// such entry — or, in Matroska, when no seek has happened yet: the index
  /// sits at the end of the file and FFmpeg reads it on the first seek.
  public func latestIndexedTime(streamIndex: Int32, atOrBefore seconds: Double) async -> Double? {
    try? await thread.run { [self] in latestIndexedTimeOnThread(streamIndex, seconds) }
  }

  /// A copy of a stream's codec parameters; nil when there is no such stream.
  public func codecParameters(streamIndex: Int32) async -> FFmpegCodecParameters? {
    (try? await thread.run { [self] in codecParametersOnThread(streamIndex) }) ?? nil
  }

  /// Files attached to the container — in Matroska, typically the fonts its
  /// subtitles are styled with.
  public func attachments() async -> [FFmpegAttachment] {
    (try? await thread.run { [self] in attachmentsOnThread() }) ?? []
  }

  /// Creates a text subtitle decoder for a stream.
  public func makeSubtitleDecoder(streamIndex: Int32) async throws -> FFmpegSubtitleDecoder {
    try await thread.run { [self] in try makeSubtitleDecoderOnThread(streamIndex: streamIndex) }
  }

  public func close() async {
    requestInterrupt()
    _ = try? await thread.run { [self] in closeOnThread() }
    thread.shutdown()
  }

  // ── Everything below runs on the dedicated thread ───

  private func openOnThread() throws {
    guard let context = avformat_alloc_context() else {
      throw FFmpegDemuxerError.openFailed(.io(0))
    }
    context.pointee.probesize = configuration.probeSize
    context.pointee.max_analyze_duration = configuration.analyzeDurationMicroseconds
    corruptDiscard.attach(to: context)
    context.pointee.interrupt_callback = AVIOInterruptCB(
      callback: { opaque in
        guard let opaque else { return 0 }
        let flag = Unmanaged<InterruptFlag>.fromOpaque(opaque).takeUnretainedValue()
        return flag.isRaised ? 1 : 0
      },
      opaque: Unmanaged.passUnretained(interruptFlag).toOpaque()
    )

    var address: String?
    var options: OpaquePointer?
    defer { av_dict_free(&options) }
    switch input {
    case .bytes(let callbacks):
      let flag = interruptFlag
      do {
        let ioContext = try FFmpegIOContext(
          callbacks: callbacks, bufferSize: configuration.ioBufferSize,
          isInterrupted: { flag.isRaised }, abandonment: readAbandonment)
        ioContext.onEnd = { [corruptDiscard] in corruptDiscard.disarmAtEnd() }
        self.ioContext = ioContext
        context.pointee.pb = ioContext.rawPointer
      } catch {
        avformat_free_context(context)
        throw error
      }
    case .address(let target, let resources):
      address = target
      resources.attach(to: context)
      for (name, value) in configuration.formatOptions { av_dict_set(&options, name, value, 0) }
    }

    // Named, the format is not probed for: a run of a playlist is known to
    // be a transport stream.
    let inputFormat = configuration.formatName.flatMap { av_find_input_format($0) }
    var mutable: UnsafeMutablePointer<AVFormatContext>? = context
    let openResult = avformat_open_input(&mutable, address, inputFormat, &options)
    guard openResult >= 0 else { throw failOpen(&mutable, openResult) }
    let infoResult = avformat_find_stream_info(mutable, nil)
    guard infoResult >= 0 else { throw failOpen(&mutable, infoResult) }
    // Finding the duration reads to the end of the file, and back.
    corruptDiscard.arm()
    self.formatContext = mutable
  }

  /// The source's own error first: FFmpeg only ever sees a code.
  private func failOpen(_ context: inout UnsafeMutablePointer<AVFormatContext>?, _ code: Int32) -> Error {
    let failure = takePendingFailure()
    avformat_close_input(&context)
    releaseInput()
    return failure ?? FFmpegDemuxerError.openFailed(FFmpegErrorCode.classify(code))
  }

  private func takePendingFailure() -> Error? {
    switch input {
    case .bytes: return ioContext?.takePendingFailure()
    case .address(_, let resources): return resources.takePendingFailure()
    }
  }

  private func releaseInput() {
    corruptDiscard.detach()
    ioContext?.release()
    ioContext = nil
    if case .address(_, let resources) = input { resources.releaseAll() }
  }

  private func durationOnThread() -> Int64? {
    guard let formatContext else { return nil }
    let value = formatContext.pointee.duration
    return value > 0 ? value : nil
  }

  private func startOnThread() -> Int64? {
    guard let formatContext else { return nil }
    let value = formatContext.pointee.start_time
    return value == FFmpegPacket.noTimestamp ? nil : value
  }

  private func streamsOnThread() -> [FFmpegStreamInfo] {
    formatContext.map(FFmpegFormatInspection.streams(in:)) ?? []
  }

  private func attachmentsOnThread() -> [FFmpegAttachment] {
    formatContext.map(FFmpegFormatInspection.attachments(in:)) ?? []
  }

  private func readPacketOnThread() throws -> FFmpegPacket? {
    guard let formatContext, let streams = formatContext.pointee.streams else {
      throw FFmpegDemuxerError.notOpened
    }
    guard let packet = av_packet_alloc() else {
      throw FFmpegDemuxerError.readFailed(.io(0))
    }
    defer {
      var mutable: UnsafeMutablePointer<AVPacket>? = packet
      av_packet_free(&mutable)
    }

    // A fresh attempt; a failure left by an earlier call is set aside, not lost.
    if case .address = input { _ = takePendingFailure() } else { ioContext?.beginRead() }
    let result = av_read_frame(formatContext, packet)
    if result < 0 {
      let code = FFmpegErrorCode.classify(result)
      if code == .endOfFile {
        // The end, as it should be: nil, not an error.
        return nil
      }
      // The source's own error comes first, whatever the code says. The IO
      // callback can only hand FFmpeg AVERROR_EXIT, which classifies as an
      // interruption; checked afterwards, a network failure would reach the
      // host as "interrupted".
      if let failure = takePendingFailure() { throw failure }
      if code == .interrupted { throw FFmpegDemuxerError.interrupted }
      throw FFmpegDemuxerError.readFailed(code)
    }

    let index = Int(packet.pointee.stream_index)
    guard index >= 0, index < Int(formatContext.pointee.nb_streams),
          let stream = streams[index] else {
      throw FFmpegDemuxerError.readFailed(.io(result))
    }

    let data: Data
    if let bytes = packet.pointee.data, packet.pointee.size > 0 {
      data = Data(bytes: bytes, count: Int(packet.pointee.size))
    } else {
      data = Data()
    }

    return FFmpegPacket(
      streamIndex: Int32(index),
      data: data,
      pts: packet.pointee.pts,
      dts: packet.pointee.dts,
      duration: packet.pointee.duration,
      timeBaseNum: stream.pointee.time_base.num,
      timeBaseDen: stream.pointee.time_base.den,
      isKeyframe: packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
      bytePosition: packet.pointee.pos >= 0 ? packet.pointee.pos : nil
    )
  }

  private func seekOnThread(seconds: Double) throws {
    guard let formatContext else { throw FFmpegDemuxerError.notOpened }
    if case .bytes(let callbacks) = input, !callbacks.canSeek {
      throw FFmpegDemuxerError.seekFailed(.invalidData)
    }
    // Wherever it lands, the source has to say again that it is at its end.
    defer { corruptDiscard.arm() }

    _ = takePendingFailure()
    // An I/O error sticks to the IO context: every later read fails with it,
    // even once the source works again. A seek is a fresh attempt.
    if let io = formatContext.pointee.pb {
      io.pointee.error = 0
      io.pointee.eof_reached = 0
    }
    let target = Int64(seconds * Double(AV_TIME_BASE))
    let result = av_seek_frame(formatContext, -1, target, AVSEEK_FLAG_BACKWARD)
    if result < 0 {
      if let failure = takePendingFailure() { throw failure }
      throw FFmpegDemuxerError.seekFailed(FFmpegErrorCode.classify(result))
    }
  }

  private func codecParametersOnThread(_ streamIndex: Int32) -> FFmpegCodecParameters? {
    guard let formatContext,
          let stream = FFmpegFormatInspection.stream(streamIndex, in: formatContext) else {
      return nil
    }
    return FFmpegCodecParameters(
      copying: stream.pointee.codecpar, timeBaseNum: stream.pointee.time_base.num,
      timeBaseDen: stream.pointee.time_base.den, sampleAspect: stream.pointee.sample_aspect_ratio)
  }

  // Decoders are made from a copy of the parameters, so each knows what it
  // was made from.
  private func makeAudioDecoderOnThread(streamIndex: Int32) throws -> FFmpegAudioDecoder {
    guard let parameters = codecParametersOnThread(streamIndex) else {
      throw FFmpegDemuxerError.notOpened
    }
    return try parameters.makeAudioDecoder()
  }

  private func makeVideoDecoderOnThread(
    streamIndex: Int32,
    preferHardware: Bool,
    softwareThreadCount: Int32
  ) throws -> FFmpegVideoDecoder {
    guard let parameters = codecParametersOnThread(streamIndex) else {
      throw FFmpegDemuxerError.notOpened
    }
    return try parameters.makeVideoDecoder(
      preferHardware: preferHardware, softwareThreadCount: softwareThreadCount)
  }

  private func latestIndexedTimeOnThread(_ streamIndex: Int32, _ seconds: Double) -> Double? {
    guard let formatContext else { return nil }
    return FFmpegFormatInspection.latestIndexedTime(
      in: formatContext, streamIndex: streamIndex, atOrBefore: seconds)
  }

  private func makeSubtitleDecoderOnThread(streamIndex: Int32) throws -> FFmpegSubtitleDecoder {
    guard let formatContext,
          let stream = FFmpegFormatInspection.stream(streamIndex, in: formatContext) else {
      throw FFmpegDemuxerError.notOpened
    }
    return try FFmpegSubtitleDecoder(
      parameters: stream.pointee.codecpar,
      timeBaseNum: stream.pointee.time_base.num,
      timeBaseDen: stream.pointee.time_base.den
    )
  }

  private func closeOnThread() {
    if formatContext != nil {
      var mutable = formatContext
      avformat_close_input(&mutable)
      formatContext = nil
    }
    releaseInput()
  }
}
