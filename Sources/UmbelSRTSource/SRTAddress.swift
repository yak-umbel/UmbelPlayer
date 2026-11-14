import Foundation
import UmbelCore

/// An address `UmbelSRTSource` accepts: `srt://host:port`, and the few
/// options SRT's own addresses carry that are not about anything but the
/// stream asked for.
///
/// What an address may not ask for is what makes the player open a port and
/// wait for a peer (`mode=listener`, `mode=rendezvous`) or choose which
/// interface to use: only what is listed gets through, in any case.
struct SRTAddress {
  let host: String
  let port: UInt16
  var latency: Int?
  var streamID: String?
  var passphrase: String?

  private static let allowed: Set<String> = ["latency", "streamid", "passphrase"]

  static func parse(_ url: URL) throws -> SRTAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "srt" else { throw UmbelError.unsupportedScheme(scheme) }
    guard let host = url.host, !host.isEmpty else {
      throw UmbelError.sourceUnavailable(detail: "address has no host")
    }
    guard let port = url.port, (1...65_535).contains(port) else {
      throw UmbelError.sourceUnavailable(detail: "address has no port")
    }
    var address = SRTAddress(host: host, port: UInt16(port))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    for item in items {
      let name = item.name.lowercased()
      guard allowed.contains(name) else {
        throw UmbelError.sourceUnavailable(detail: "address option not allowed: \(name)")
      }
      switch name {
      case "latency":
        guard let value = item.value.flatMap({ Int($0) }), (0...60_000).contains(value) else {
          throw UmbelError.sourceUnavailable(detail: "address option latency is not a number of milliseconds")
        }
        address.latency = value
      case "streamid": address.streamID = item.value
      default: address.passphrase = item.value
      }
    }
    return address
  }
}
