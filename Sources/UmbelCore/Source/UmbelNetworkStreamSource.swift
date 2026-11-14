import Foundation
import UmbelFFmpegSupport

/// A live stream off the network, over a protocol FFmpeg reads itself:
/// `rtmp`, `rtmps`, `udp` and `tcp` (a transport stream sent over a plain
/// connection), and `rtmpt` and `rtmpts`, which carry RTMP in HTTP requests
/// for a network that lets nothing else through.
///
/// Read once and in order, so the session reports it cannot seek. A stream
/// that is cut is an error, not something to carry on from — the host
/// decides whether to open it again. A stream that ends where it was meant
/// to is the end.
///
/// The connection is FFmpeg's own, so it does not follow the system's proxy
/// settings or App Transport Security, and `rtmp`, `udp` and `tcp` are not
/// encrypted. Which address is opened is the host's choice, by creating this
/// source for it; any other scheme is refused here, before anything is
/// opened.
///
/// An error never carries the address, which commonly holds a token.
public actor UmbelNetworkStreamSource: UmbelStreamingSource {
  public struct Configuration: Sendable {
    /// How long opening may take, the first exchange with the server
    /// included. FFmpeg's own timeouts do not cover a peer that never
    /// answers; this does.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for bytes before the stream counts as lost.
    public var stallTimeout: TimeInterval
    /// For `rtmps` and `rtmpts`: a file of certificate authorities (PEM) to trust,
    /// for a server whose certificate the system does not know. Certificates
    /// are always checked; there is no way to turn that off.
    public var certificateAuthorityFile: URL?

    public init(
      connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20,
      certificateAuthorityFile: URL? = nil
    ) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.certificateAuthorityFile = certificateAuthorityFile
    }
  }

  private let stream: UmbelBlockingStreamSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but those above,
  /// and `sourceUnavailable` for an address option that is not allowed.
  /// Nothing is opened until the first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    let address = try NetworkStreamAddress.parse(url, certificateAuthorityFile: configuration.certificateAuthorityFile)
    let reader = FFmpegProtocolReader(
      address: address.text,
      configuration: .init(
        allowedProtocols: address.allowedProtocols, options: address.options,
        connectTimeout: configuration.connectTimeout, stallTimeout: configuration.stallTimeout))
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
