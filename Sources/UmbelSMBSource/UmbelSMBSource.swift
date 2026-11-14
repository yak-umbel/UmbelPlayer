import Foundation
import UmbelCore

/// A file on an SMB share, read from anywhere: `smb://[domain;][user[:password]@]host[:port]/share/path`.
///
/// Random access, so the session can seek. The login is NTLM, or guest when
/// the address has no user; Kerberos is not offered. With a login, signing is
/// used whenever the server asks for it, and SMB3 encryption is required when
/// the configuration says so: it keeps the file from the network (without it,
/// SMB is not encrypted, and the login proves the password without sending
/// it). A guest has no key to encrypt with, and asking for it for one is refused.
///
/// A read that fails says so and nothing is retried; the host decides. A read
/// that is cancelled gives up at once, and the connection, left in a state
/// nobody knows, is closed; the next read opens one again.
///
/// The connection is libsmb2's own, so it does not follow the system's proxy
/// settings. An error never carries the address, a user name or a password.
public actor UmbelSMBSource: UmbelRandomAccessSource {
  public struct Configuration: Sendable {
    /// How long connecting and logging in may take.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for bytes before the transfer counts as lost.
    public var stallTimeout: TimeInterval
    /// The domain, if it is not in the address (`DOMAIN;user@`); this wins.
    public var domain: String?
    /// The password, if it is not in the address; this wins.
    public var password: String?
    /// Refuse a server that does not encrypt (SMB 3).
    public var requireEncryption: Bool

    public init(
      connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, domain: String? = nil,
      password: String? = nil, requireEncryption: Bool = false
    ) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.domain = domain
      self.password = password
      self.requireEncryption = requireEncryption
    }
  }

  private let file: UmbelBlockingFileSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `smb`, and
  /// `sourceUnavailable` for an address with no host, share or file, one with
  /// an option, or encryption required of a guest. Nothing is opened until
  /// the first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    let address = try SMBAddress.parse(url)
    // A guest has no session key to encrypt with.
    if address.user == nil, configuration.requireEncryption {
      throw UmbelError.sourceUnavailable(detail: "encryption needs a login")
    }
    file = UmbelBlockingFileSource(
      reader: SMBReader(
        settings: .init(
          address: address, password: configuration.password ?? address.password,
          domain: configuration.domain ?? address.domain, connectTimeout: configuration.connectTimeout,
          stallTimeout: configuration.stallTimeout, requireEncryption: configuration.requireEncryption)))
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

  /// The library this module brings, for an app to acknowledge: libsmb2, which
  /// is under the LGPL and is a dynamic library of its own.
  public static var thirdPartyNotices: [UmbelThirdPartyNotice] {
    guard let url = Bundle.module.url(forResource: "libsmb2", withExtension: "txt", subdirectory: "Texts"),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      preconditionFailure("Missing bundled license text for libsmb2")
    }
    return [UmbelThirdPartyNotice(name: "libsmb2", version: "6.3.0", license: "LGPL-2.1-or-later", text: text)]
  }
}
