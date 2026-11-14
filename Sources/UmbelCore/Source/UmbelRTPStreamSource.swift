import Foundation
import UmbelFFmpegSupport

/// A live stream over RTSP or RTP, as the bytes of a container.
///
/// RTSP and RTP are not byte streams: FFmpeg's demuxer for them opens its own
/// connection and gives packets. This source takes those packets, tidies their
/// timestamps and writes them to a container in memory (Matroska if it will
/// hold the streams, else NUT, else MPEG-TS), which is what it hands on. Any
/// codec the streams carry passes through as it is; nothing is decoded.
///
/// `rtsp://` asks the server for the stream (over TCP unless told otherwise);
/// `rtp://` joins a stream sent to a UDP port, or to a multicast group. An RTP
/// address has no description of the stream with it, so only what FFmpeg
/// recognises without one — an MPEG transport stream — can be played that way.
///
/// Read once and in order, so the session reports it cannot seek. A stream
/// that is cut is an error, not something to carry on from; the host decides
/// whether to open it again. So is a stream that ends: FFmpeg's demuxer ends
/// it the same way whether the server finished it or the connection was lost,
/// and for a live stream the second is the one that must not pass as the first.
///
/// The connection is FFmpeg's own: it does not follow the system's proxy
/// settings or App Transport Security, and neither RTSP nor RTP here is
/// encrypted. UDP does not retransmit.
///
/// An error never carries the address, which commonly holds a token.
public actor UmbelRTPStreamSource: UmbelStreamingSource {
  /// How RTSP carries the media.
  public enum Transport: String, Sendable {
    /// Interleaved with the control connection: through anything that lets
    /// the connection through.
    case tcp
    /// On UDP ports of their own: lower latency, and loses what the network
    /// loses.
    case udp
  }

  public struct Configuration: Sendable {
    /// How long opening may take: the first exchange with the server, and
    /// the wait for enough of the stream to tell what it holds.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for a packet before the stream counts as lost.
    public var stallTimeout: TimeInterval
    /// For `rtsp://`; an RTP address has no say in it.
    public var transport: Transport

    public init(connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, transport: Transport = .tcp) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.transport = transport
    }
  }

  private let stream: UmbelBlockingStreamSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `rtsp` and
  /// `rtp`, and `sourceUnavailable` for an RTP address option that is not
  /// allowed. Nothing is opened until the first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    let address = try PacketStreamAddress.parse(url, transport: configuration.transport)
    let reader = FFmpegPacketRepackager(
      address: address.text,
      configuration: .init(
        inputFormat: address.inputFormat, allowedProtocols: address.allowedProtocols, options: address.options,
        connectTimeout: configuration.connectTimeout, stallTimeout: configuration.stallTimeout,
        endIsFailure: true))
    stream = UmbelBlockingStreamSource(pump: NetworkStreamPump(reader: reader, queue: LiveByteQueue()))
  }

  /// A live stream has no length.
  public var contentLength: Int64? { nil }

  public func readNext(maxLength: Int) async throws -> Data {
    try await stream.readNext(maxLength: maxLength)
  }

  public func invalidate() async {
    await stream.invalidate()
  }
}
