import Foundation

/// An address `UmbelNetworkStreamSource` accepts, and what FFmpeg is let to
/// do with it.
///
/// FFmpeg reads options out of an address as well as opening it: a TCP
/// address with `listen=1` makes the player open a port and wait for a peer.
/// So the scheme must be on a short list, and a TCP or UDP address may carry
/// only the options named here. An RTMP address's query (`rtmp`, `rtmps` and
/// their tunnelled forms) is the server's own — a token, a stream list — and
/// goes through as it is.
struct NetworkStreamAddress {
  /// Lower case.
  let scheme: String
  /// What FFmpeg is given.
  let text: String
  /// The protocols FFmpeg may open for it, and no others.
  let allowedProtocols: [String]
  /// FFmpeg's own options to open it with.
  let options: [String: String]

  private static let protocols: [String: [String]] = [
    "rtmp": ["rtmp", "tcp"],
    "rtmps": ["rtmps", "tls", "tcp"],
    // RTMP carried in HTTP requests, for networks that let nothing else through.
    "rtmpt": ["rtmpt", "ffrtmphttp", "http", "tcp"],
    "rtmpts": ["rtmpts", "ffrtmphttp", "https", "tls", "tcp"],
    "udp": ["udp"],
    "tcp": ["tcp"],
  ]

  /// Options an address may carry, by scheme; none for a scheme not listed.
  /// Nothing here opens a port or sends to anywhere else.
  private static let addressOptions: [String: Set<String>] = [
    "udp": ["pkt_size", "fifo_size", "overrun_nonfatal", "buffer_size", "reuse", "sources", "localaddr"],
    "tcp": [],
  ]

  static func parse(_ url: URL, certificateAuthorityFile: URL?) throws -> NetworkStreamAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    guard var allowedProtocols = protocols[scheme] else { throw UmbelError.unsupportedScheme(scheme) }
    if let allowed = addressOptions[scheme] {
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      for item in items where !allowed.contains(item.name.lowercased()) {
        throw UmbelError.sourceUnavailable(detail: "address option not allowed: \(item.name.lowercased())")
      }
    }
    var options: [String: String] = [:]
    switch scheme {
    case "udp": options["overrun_nonfatal"] = "1"
    case "tcp": options["listen"] = "0"
    case "rtmps", "rtmpts":
      if let file = certificateAuthorityFile {
        options["ca_file"] = file.path
        // The system's TLS reads the file through FFmpeg's `file` protocol. Only
        // for this path, which is the host's, and never for an address.
        allowedProtocols.append("file")
      }
    default: break
    }
    return NetworkStreamAddress(
      scheme: scheme, text: url.absoluteString, allowedProtocols: allowedProtocols, options: options)
  }
}
