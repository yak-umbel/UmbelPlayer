import Foundation

/// An address `UmbelRTPStreamSource` accepts, and what FFmpeg is let to do
/// with it: `rtsp` and `rtp`, whose demuxers open the connection themselves.
///
/// An RTSP address's query is the server's own (a token) and goes through as
/// it is. An RTP address is a socket: FFmpeg reads options out of it, and
/// only those that cannot open a port to wait on or send somewhere else are
/// let through, as for a UDP address.
struct PacketStreamAddress {
  /// Lower case.
  let scheme: String
  /// What FFmpeg is given.
  let text: String
  /// The demuxer to open it with.
  let inputFormat: String
  /// The protocols FFmpeg may open for it, and no others.
  let allowedProtocols: [String]
  /// FFmpeg's own options to open it with.
  let options: [String: String]

  private static let rtpOptions: Set<String> = [
    "pkt_size", "fifo_size", "overrun_nonfatal", "buffer_size", "reuse", "sources", "localaddr",
  ]

  static func parse(_ url: URL, transport: UmbelRTPStreamSource.Transport) throws -> PacketStreamAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    switch scheme {
    case "rtsp":
      return PacketStreamAddress(
        scheme: scheme, text: url.absoluteString, inputFormat: "rtsp",
        allowedProtocols: ["rtsp", "rtp", "tcp", "udp"], options: ["rtsp_transport": transport.rawValue])
    case "rtp":
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      for item in items where !rtpOptions.contains(item.name.lowercased()) {
        throw UmbelError.sourceUnavailable(detail: "address option not allowed: \(item.name.lowercased())")
      }
      return PacketStreamAddress(
        scheme: scheme, text: url.absoluteString, inputFormat: "rtp", allowedProtocols: ["rtp", "udp"], options: [:])
    default:
      throw UmbelError.unsupportedScheme(scheme)
    }
  }
}
