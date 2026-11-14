import FFmpeg
import Foundation

/// Reads a stream FFmpeg's own demuxer opens the connection for — RTSP, RTP —
/// and hands it on as the bytes of one container, which any demuxer can read.
///
/// Such a demuxer takes no bytes: it makes its own connection and gives
/// packets. The packets are written to a container held in memory, as they
/// come, and what the container writes is what `read` returns.
///
/// The container is the first of `Configuration.containers` that accepts the
/// streams: some carry parameters another cannot, as the sound of a transport
/// stream in RTP lacks what Matroska's header asks for.
///
/// Timestamps are made what a container takes; see `FFmpegTimestampTidy`.
///
/// Every call but `requestInterrupt()` blocks, and has to be made from one
/// thread; see `FFmpegByteReading`.
public final class FFmpegPacketRepackager: FFmpegByteReading, @unchecked Sendable {
  public struct Configuration: Sendable {
    /// The demuxer to open the address with: `rtsp`, `rtp`.
    public var inputFormat: String
    /// What FFmpeg may open, by protocol name: `rtsp` needs `tcp` or `udp` too.
    public var allowedProtocols: [String]
    /// FFmpeg's own options for the demuxer (`rtsp_transport`).
    public var options: [String: String]
    /// Containers to write, in order of preference.
    public var containers: [String]
    /// How long opening may take, probing the streams included.
    public var connectTimeout: TimeInterval
    /// How long one wait for a packet may take.
    public var stallTimeout: TimeInterval
    /// Whether the end of the input is a failure. RTSP's demuxer ends the same
    /// way when the server finishes a stream as when the connection is lost;
    /// of a live stream, the second is what has to be told. The container is
    /// then not closed either: its end would be read as the stream finishing,
    /// before the source is asked for more.
    public var endIsFailure: Bool

    public init(
      inputFormat: String, allowedProtocols: [String], options: [String: String] = [:],
      containers: [String] = ["matroska", "nut", "mpegts"],
      connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, endIsFailure: Bool = false
    ) {
      self.inputFormat = inputFormat
      self.allowedProtocols = allowedProtocols
      self.options = options
      self.containers = containers
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.endIsFailure = endIsFailure
    }
  }

  /// What a container writes, until it is read.
  fileprivate final class OutputSink {
    var pending = Data()
  }

  private static let sinkBufferSize = 32 << 10
  /// A stream that stops must not hold back the others for long: the default,
  /// ten seconds, would.
  private static let largestInterleaveDelay: Int64 = 1_000_000

  private let address: String
  private let configuration: Configuration
  private let state = InterruptState()
  private let sink = OutputSink()
  private var input: UnsafeMutablePointer<AVFormatContext>?
  private var output: UnsafeMutablePointer<AVFormatContext>?
  private var packet: UnsafeMutablePointer<AVPacket>?
  /// Where each input stream goes in the output; -1 for one left out.
  private var streamMap: [Int32] = []
  private var timestamps = FFmpegTimestampTidy(streams: 0)
  private var isFinished = false

  public init(address: String, configuration: Configuration) {
    self.address = address
    self.configuration = configuration
  }

  deinit { close() }

  public func requestInterrupt() {
    state.request()
  }

  public func open() throws {
    state.arm(after: configuration.connectTimeout)
    defer { state.disarm() }
    guard let context = avformat_alloc_context() else {
      throw FFmpegStreamFailure.failed(.io(-ENOMEM))
    }
    context.pointee.interrupt_callback = AVIOInterruptCB(
      callback: { opaque in
        guard let opaque else { return 0 }
        return Unmanaged<InterruptState>.fromOpaque(opaque).takeUnretainedValue().shouldInterrupt() ? 1 : 0
      },
      opaque: Unmanaged.passUnretained(state).toOpaque())
    var options: OpaquePointer?
    defer { av_dict_free(&options) }
    av_dict_set(&options, "protocol_whitelist", configuration.allowedProtocols.joined(separator: ","), 0)
    for (name, value) in configuration.options { av_dict_set(&options, name, value, 0) }
    var opened: UnsafeMutablePointer<AVFormatContext>? = context
    let format = av_find_input_format(configuration.inputFormat)
    let result = avformat_open_input(&opened, address, format, &options)
    // On failure FFmpeg has freed the context.
    guard result >= 0, let opened else { throw state.failure(for: result, during: .connecting) }
    input = opened
    let info = avformat_find_stream_info(opened, nil)
    guard info >= 0 else {
      close()
      throw state.failure(for: info, during: .connecting)
    }
    guard let made = av_packet_alloc() else {
      close()
      throw FFmpegStreamFailure.failed(.io(-ENOMEM))
    }
    packet = made
    guard chooseContainer(for: opened) else {
      close()
      throw FFmpegStreamFailure.failed(.invalidData)
    }
  }

  public func read(maxLength: Int) throws -> Data {
    guard let input, let output, let packet, !state.isRequested else { throw FFmpegStreamFailure.interrupted }
    while sink.pending.isEmpty, !isFinished {
      state.arm(after: configuration.stallTimeout)
      let result = av_read_frame(input, packet)
      state.disarm()
      if result < 0 {
        if FFmpegErrorCode.classify(result) == .endOfFile, !state.isRequested {
          if configuration.endIsFailure { throw FFmpegStreamFailure.failed(.endOfFile) }
          av_write_trailer(output)
          avio_flush(output.pointee.pb)
          isFinished = true
          break
        }
        throw state.failure(for: result, during: .receiving)
      }
      defer { av_packet_unref(packet) }
      try write(packet, from: input, to: output)
    }
    let count = min(max(1, maxLength), sink.pending.count)
    guard count > 0 else { return Data() }
    let bytes = Data(sink.pending.prefix(count))
    sink.pending.removeFirst(count)
    return bytes
  }

  public func close() {
    if let output {
      self.output = nil
      Self.release(output)
    }
    if input != nil { avformat_close_input(&input) }
    if packet != nil { av_packet_free(&packet) }
  }

  // ── The container ───────────────────────────────────

  /// Writes the header to the first container that takes every stream there
  /// is to carry. Streams of any other kind (data) are left out.
  private func chooseContainer(for input: UnsafeMutablePointer<AVFormatContext>) -> Bool {
    for name in configuration.containers {
      var made: UnsafeMutablePointer<AVFormatContext>?
      guard avformat_alloc_output_context2(&made, nil, name, nil) >= 0, let candidate = made else { continue }
      guard let buffer = av_malloc(Self.sinkBufferSize),
            let io = avio_alloc_context(
              buffer.assumingMemoryBound(to: UInt8.self), Int32(Self.sinkBufferSize), 1,
              Unmanaged.passUnretained(sink).toOpaque(), nil, umbelSinkWrite, nil)
      else {
        avformat_free_context(candidate)
        continue
      }
      candidate.pointee.pb = io
      candidate.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
      candidate.pointee.max_interleave_delta = Self.largestInterleaveDelay
      var map = [Int32](repeating: -1, count: Int(input.pointee.nb_streams))
      var carried: Int32 = 0
      var complete = true
      for index in 0..<map.count {
        guard let stream = input.pointee.streams[index] else { continue }
        let kind = stream.pointee.codecpar.pointee.codec_type
        guard kind == AVMEDIA_TYPE_AUDIO || kind == AVMEDIA_TYPE_VIDEO || kind == AVMEDIA_TYPE_SUBTITLE else { continue }
        guard let made = avformat_new_stream(candidate, nil),
              avcodec_parameters_copy(made.pointee.codecpar, stream.pointee.codecpar) >= 0 else {
          complete = false
          break
        }
        // The container's own tag for the codec, not the input's.
        made.pointee.codecpar.pointee.codec_tag = 0
        made.pointee.time_base = stream.pointee.time_base
        map[index] = carried
        carried += 1
      }
      if complete, carried > 0, avformat_write_header(candidate, nil) >= 0 {
        output = candidate
        streamMap = map
        timestamps = FFmpegTimestampTidy(streams: Int(carried))
        avio_flush(io)
        return true
      }
      Self.release(candidate)
      // Whatever a failed header wrote is not part of the stream.
      sink.pending.removeAll()
    }
    return false
  }

  private func write(
    _ packet: UnsafeMutablePointer<AVPacket>, from input: UnsafeMutablePointer<AVFormatContext>,
    to output: UnsafeMutablePointer<AVFormatContext>
  ) throws {
    let inIndex = Int(packet.pointee.stream_index)
    guard inIndex >= 0, inIndex < streamMap.count, streamMap[inIndex] >= 0,
          let source = input.pointee.streams[inIndex] else { return }
    let outIndex = Int(streamMap[inIndex])
    guard let destination = output.pointee.streams[outIndex] else { return }
    packet.pointee.stream_index = Int32(outIndex)
    av_packet_rescale_ts(packet, source.pointee.time_base, destination.pointee.time_base)
    guard let times = timestamps.tidy(stream: outIndex, dts: packet.pointee.dts, pts: packet.pointee.pts) else { return }
    packet.pointee.dts = times.dts
    packet.pointee.pts = times.pts
    let result = av_interleaved_write_frame(output, packet)
    avio_flush(output.pointee.pb)
    if result < 0 { throw FFmpegStreamFailure.failed(FFmpegErrorCode.classify(result)) }
  }

  /// Frees a container that was made here, and the I/O beneath it.
  private static func release(_ context: UnsafeMutablePointer<AVFormatContext>) {
    if var io = context.pointee.pb {
      av_free(io.pointee.buffer)
      var optional: UnsafeMutablePointer<AVIOContext>? = io
      avio_context_free(&optional)
      io = optional ?? io
    }
    context.pointee.pb = nil
    avformat_free_context(context)
  }
}

/// Takes what a container writes, in the order it writes it.
private func umbelSinkWrite(
  _ opaque: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ size: Int32
) -> Int32 {
  guard let opaque, let bytes, size > 0 else { return 0 }
  Unmanaged<FFmpegPacketRepackager.OutputSink>.fromOpaque(opaque).takeUnretainedValue()
    .pending.append(bytes, count: Int(size))
  return size
}
