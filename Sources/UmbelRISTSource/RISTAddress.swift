import Foundation
import UmbelCore

/// An address `UmbelRISTSource` accepts: `rist://host:port`, and the options
/// of a RIST address that are about the stream asked for and nothing else.
///
/// What an address may not ask for is what makes the player open a port and
/// wait for a sender (an `@` before the host), choose which interface to use,
/// or log in with SRP, which this build of the library cannot do: only what
/// is listed gets through, in any case. Options are checked here, and given
/// to the library as values, not as text for it to read again: a passphrase
/// with an `&` or a `/` in it reaches it as it is.
struct RISTAddress {
  let host: String
  let port: UInt16
  /// The numeric options that were given, by name.
  private(set) var numbers: [String: Int] = [:]
  private(set) var secret: String?
  private(set) var cname: String?

  /// Each numeric option's range, as the library takes it.
  private static let ranges: [String: ClosedRange<Int>] = [
    "buffer": 1...60_000, "buffer-min": 0...60_000, "buffer-max": 1...60_000, "reorder-buffer": 0...60_000,
    "rtt-min": 0...60_000, "rtt-max": 0...60_000, "bandwidth": 1...100_000_000, "return-bandwidth": 0...100_000_000,
    "key-rotation": 1...1_000_000_000, "compression": 0...1, "virt-dst-port": 1...65_535,
    "session-timeout": 1...3_600_000, "keepalive-interval": 1...3_600_000, "congestion-control": 0...2,
    "timing-mode": 0...2, "min-retries": 1...1_000, "max-retries": 1...1_000,
  ]
  private static let textLimit = 127

  static func parse(_ url: URL) throws -> RISTAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "rist" else { throw UmbelError.unsupportedScheme(scheme) }
    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    // An `@` before the host, empty or not, is how a RIST address says "listen".
    if parts?.user != nil || parts?.password != nil {
      throw UmbelError.sourceUnavailable(detail: "address would make the player listen")
    }
    // An IPv6 literal comes with its brackets; the host does not.
    var host = parts?.host ?? ""
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard !host.isEmpty else {
      throw UmbelError.sourceUnavailable(detail: "address has no host")
    }
    guard let port = parts?.port, (1...65_535).contains(port) else {
      throw UmbelError.sourceUnavailable(detail: "address has no port")
    }
    guard (parts?.path ?? "").isEmpty || parts?.path == "/", parts?.fragment == nil else {
      throw UmbelError.sourceUnavailable(detail: "address has a path")
    }
    var address = RISTAddress(host: host, port: UInt16(port))
    var seen: Set<String> = []
    for item in parts?.queryItems ?? [] {
      let name = item.name.lowercased()
      guard seen.insert(name).inserted else {
        throw UmbelError.sourceUnavailable(detail: "address option given twice: \(name)")
      }
      try address.set(name, item.value ?? "")
    }
    return address
  }

  /// Takes an option, from the address or from the configuration, which
  /// calls this after it and so wins.
  mutating func set(_ name: String, _ value: String) throws {
    let invalid = UmbelError.sourceUnavailable(detail: "address option \(name) is not valid")
    switch name {
    case "secret", "cname":
      guard !value.isEmpty, value.utf8.count <= Self.textLimit, !value.utf8.contains(0) else { throw invalid }
      if name == "secret" { secret = value } else { cname = value }
    case "aes-type":
      guard let bits = Int(value), bits == 128 || bits == 256 else { throw invalid }
      numbers[name] = bits
    default:
      guard let range = Self.ranges[name] else {
        throw UmbelError.sourceUnavailable(detail: "address option not allowed: \(name)")
      }
      // Digits only: `Int("+5")` and a leading space would otherwise do.
      guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), range.contains(number)
      else { throw invalid }
      numbers[name] = number
    }
  }
}
