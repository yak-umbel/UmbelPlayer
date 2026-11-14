import Foundation
import UmbelCore

/// A file on an NFS export, read from anywhere: `nfs://host[:port]/export/…/file`,
/// where the file is the last name and the export the directory it is in, or
/// `?export=/shared` says which part of the path is the export.
///
/// Random access, so the session can seek. NFS version 3 over TCP, with
/// `AUTH_SYS`: there is no login and no encryption. The server trusts the user
/// and group the client says it has (`userID` and `groupID`, the app's own
/// otherwise) and sends the file as it is to anyone on the way: use it on a
/// network you trust. A server whose MOUNT service is not on the portmapper
/// needs `?mountport=`. Kerberos, TLS and NFS version 4 are not offered.
///
/// A read that fails says so and nothing is retried; the host decides. A read
/// that is cancelled gives up at once, and the connection, left in a state
/// nobody knows, is closed; the next read opens one again. An error never
/// carries the address.
///
/// libnfs makes the process ignore `SIGPIPE`, as many network libraries do, when
/// it makes a connection: it writes to sockets the other side may have closed.
public actor UmbelNFSSource: UmbelRandomAccessSource {
  public struct Configuration: Sendable {
    /// How long connecting and mounting may take.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for bytes before the transfer counts as lost.
    public var stallTimeout: TimeInterval
    /// The user the server is told the calls are from; the app's own if nil.
    public var userID: Int?
    /// The group the server is told the calls are from; the app's own if nil.
    public var groupID: Int?

    public init(connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, userID: Int? = nil, groupID: Int? = nil) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.userID = userID
      self.groupID = groupID
    }
  }

  private let file: UmbelBlockingFileSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `nfs`, and
  /// `sourceUnavailable` for an address with no host or file, one with a login
  /// or an option that is not allowed. Nothing is opened until the first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    let address = try NFSAddress.parse(url)
    file = UmbelBlockingFileSource(
      reader: NFSReader(
        settings: .init(
          address: address, userID: configuration.userID, groupID: configuration.groupID,
          connectTimeout: configuration.connectTimeout, stallTimeout: configuration.stallTimeout)))
  }

  public var contentLength: Int64? {
    get async { await file.contentLength }
  }

  public func read(offset: Int64, maxLength: Int) async throws -> Data {
    try await file.read(offset: offset, maxLength: maxLength)
  }

  public func invalidate() async {
    await file.invalidate()
  }

  /// The library this module brings, for an app to acknowledge: libnfs, which
  /// is under the LGPL and is a dynamic library of its own.
  public static var thirdPartyNotices: [UmbelThirdPartyNotice] {
    guard let url = Bundle.module.url(forResource: "libnfs", withExtension: "txt", subdirectory: "Texts"),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      preconditionFailure("Missing bundled license text for libnfs")
    }
    return [UmbelThirdPartyNotice(name: "libnfs", version: "8.0.0", license: "LGPL-2.1-or-later", text: text)]
  }
}
