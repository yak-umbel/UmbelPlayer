import Foundation
import UmbelCore

/// An address `UmbelNFSSource` accepts: `nfs://host[:port]/export/…/file`.
///
/// NFS names the file in two parts, the export the server shares and the path
/// in it, and a URL does not say where one ends. Without an option the file is
/// the last name and the export the directory it is in; `?export=/shared` says
/// the export, and the rest of the path is the file in it. The other option is
/// `?mountport=`, for a server whose MOUNT service is not found through the
/// portmapper. There is no login: NFS trusts the user and group the client
/// says it has, which the configuration sets.
struct NFSAddress {
  let host: String
  /// The NFS port, if it is not the standard one.
  let port: UInt16?
  let mountPort: UInt16?
  /// As the server shares it, with a `/` before it.
  let export: String
  /// The file's, relative to the export.
  let path: String

  static func parse(_ url: URL) throws -> NFSAddress {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "nfs" else { throw UmbelError.unsupportedScheme(scheme) }
    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw UmbelError.sourceUnavailable(detail: "address is not valid")
    }
    guard parts.user == nil, parts.password == nil else {
      throw UmbelError.sourceUnavailable(detail: "address has a login")
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
    var export: String?
    var mountPort: UInt16?
    var seen: Set<String> = []
    for item in parts.queryItems ?? [] {
      let name = item.name.lowercased()
      guard seen.insert(name).inserted else { throw UmbelError.sourceUnavailable(detail: "address option given twice: \(name)") }
      switch name {
      case "export":
        guard let value = item.value, value.hasPrefix("/"), !value.utf8.contains(0) else {
          throw UmbelError.sourceUnavailable(detail: "address option export is not valid")
        }
        export = value
      case "mountport":
        guard let value = item.value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
          let number = UInt16(value), number > 0
        else { throw UmbelError.sourceUnavailable(detail: "address option mountport is not valid") }
        mountPort = number
      default:
        throw UmbelError.sourceUnavailable(detail: "address option not allowed: \(name)")
      }
    }
    let names = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !names.isEmpty, !parts.path.hasSuffix("/") else { throw UmbelError.sourceUnavailable(detail: "address has no file path") }
    if let export {
      let shared = export.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
      guard names.count > shared.count, Array(names.prefix(shared.count)) == shared else {
        throw UmbelError.sourceUnavailable(detail: "address is not a file in the export")
      }
      return NFSAddress(
        host: host, port: port, mountPort: mountPort, export: "/" + shared.joined(separator: "/"),
        path: names.dropFirst(shared.count).joined(separator: "/"))
    }
    return NFSAddress(
      host: host, port: port, mountPort: mountPort, export: "/" + names.dropLast().joined(separator: "/"),
      path: names[names.count - 1])
  }
}
