import Foundation
import UmbelCore

/// An address `UmbelSMBSource` accepts: `smb://[domain;][user[:password]@]host[:port]/share/path`.
///
/// What is in it is checked here and given to the library as values, not as
/// text for it to read again: a password with a `/` or an `@` in it reaches it
/// as it is. There are no options, and an address that carries any is refused.
struct SMBAddress {
  let host: String
  let port: UInt16?
  let share: String
  /// The file's, relative to the share, as the server takes it.
  let path: String
  let domain: String?
  let user: String?
  let password: String?

  /// The server as libsmb2 reads it: the host, with brackets round an IPv6
  /// address, and `:port` if there is one.
  var server: String {
    (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
  }

  static func parse(_ url: URL) throws -> SMBAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "smb" else { throw UmbelError.unsupportedScheme(scheme) }
    // The URL's own accessors give the user and password as written,
    // percent-encoding and all; the components' give them as they were meant.
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw UmbelError.sourceUnavailable(detail: "address is not valid")
    }
    var host = parts.host ?? ""
    // An IPv6 literal comes with its brackets; the host does not.
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard !host.isEmpty else { throw UmbelError.sourceUnavailable(detail: "address has no host") }
    var port: UInt16?
    if let given = parts.port {
      guard (1...65_535).contains(given) else { throw UmbelError.sourceUnavailable(detail: "address has an invalid port") }
      port = UInt16(given)
    }
    if let query = parts.queryItems, !query.isEmpty {
      throw UmbelError.sourceUnavailable(detail: "address options not allowed")
    }
    // The first segment is the share, the rest the file.
    let segments = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let share = segments.first else { throw UmbelError.sourceUnavailable(detail: "address has no share") }
    guard segments.count > 1, !parts.path.hasSuffix("/") else {
      throw UmbelError.sourceUnavailable(detail: "address has no file path")
    }
    var user = parts.user.flatMap { $0.isEmpty ? nil : $0 }
    var domain: String?
    if let combined = user, let split = combined.firstIndex(of: ";") {
      domain = String(combined[..<split])
      user = String(combined[combined.index(after: split)...])
    }
    return SMBAddress(
      host: host, port: port, share: share, path: segments.dropFirst().joined(separator: "/"),
      domain: domain, user: user, password: parts.password)
  }
}
