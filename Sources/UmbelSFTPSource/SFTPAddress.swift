import Foundation
import UmbelCore

/// An address `UmbelSFTPSource` accepts: `sftp://[user[:password]@]host[:port]/path`.
///
/// The path is the file's, absolute on the server. There are no options: an
/// address that carries any is refused, so that nothing in it can change how
/// the connection is made.
struct SFTPAddress {
  let host: String
  let port: UInt16
  let path: String
  var username: String?
  var password: String?

  static func parse(_ url: URL) throws -> SFTPAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "sftp" else { throw UmbelError.unsupportedScheme(scheme) }
    guard let host = url.host, !host.isEmpty else {
      throw UmbelError.sourceUnavailable(detail: "address has no host")
    }
    let port = url.port ?? 22
    guard (1...65_535).contains(port) else {
      throw UmbelError.sourceUnavailable(detail: "address has an invalid port")
    }
    let path = url.path
    guard path.count > 1 else { throw UmbelError.sourceUnavailable(detail: "address has no file path") }
    // The URL's own accessors give the user and password as written, percent-encoding and all.
    let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    if let query = parts?.queryItems, !query.isEmpty {
      throw UmbelError.sourceUnavailable(detail: "address options not allowed")
    }
    return SFTPAddress(host: host, port: UInt16(port), path: path, username: parts?.user, password: parts?.password)
  }
}
