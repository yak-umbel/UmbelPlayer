import Foundation
import UmbelCore

/// A file on an SFTP server, read from anywhere: `sftp://[user@]host[:port]/path`.
///
/// SFTP is the file transfer of SSH, so the connection is encrypted and the
/// server proves who it is. That proof is the point: **the host key is judged
/// before anything is sent to the server, and a source with nobody to judge it
/// does not exist** — there is no way to connect without deciding which keys
/// to trust. Pass the fingerprints the app trusts to `trusting(fingerprints:)`,
/// or a verifier of your own.
///
/// Random access, so the session can seek. A read that fails says so and
/// nothing is retried; the host decides. A read that is cancelled gives up at
/// once, and the connection, left in a state nobody knows, is closed; the
/// next read opens one again — and judges the host key again.
///
/// The connection is libssh2's own, so it does not follow the system's proxy
/// settings. An error never carries the address, a password or a key.
public actor UmbelSFTPSource: UmbelRandomAccessSource {
  /// A key the server presented to prove who it is.
  public struct HostKey: Sendable, Equatable {
    /// The key's type as SSH names it, such as `ssh-ed25519`.
    public let type: String
    /// The public key as the server sent it.
    public let raw: Data
    /// SHA-256 of `raw`.
    public let sha256: Data

    public init(type: String, raw: Data, sha256: Data) {
      self.type = type
      self.raw = raw
      self.sha256 = sha256
    }

    /// The form OpenSSH shows and `ssh-keygen -l` prints: `SHA256:` and the
    /// digest in base 64 without padding.
    public var fingerprint: String {
      "SHA256:" + sha256.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
  }

  /// How the server is told who is asking. The user name is the address's.
  public enum Authentication: Sendable {
    /// The password, if it is not in the address.
    case password(String)
    /// A private key in a file, and the public key beside it if libssh2 is
    /// to be given one, and the passphrase if the key has one.
    case privateKey(file: URL, publicKeyFile: URL? = nil, passphrase: String? = nil)
  }

  public struct Configuration: Sendable {
    /// How long connecting, the key exchange and logging in may take.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for bytes before the transfer counts as lost.
    public var stallTimeout: TimeInterval
    /// What to log in with; the address's `user:password@` if nil.
    public var authentication: Authentication?

    public init(connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, authentication: Authentication? = nil) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.authentication = authentication
    }
  }

  private let file: UmbelBlockingFileSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `sftp`, and
  /// `sourceUnavailable` for an address with no host or file, one with an
  /// option, or when there is no way to log in. Nothing is opened until the
  /// first read.
  ///
  /// `hostKeyVerifier` is asked, on every connection, whether the server's key
  /// is one to trust; if it says no the connection is dropped before any
  /// credential is sent.
  public init(
    url: URL, configuration: Configuration = Configuration(),
    hostKeyVerifier: @escaping @Sendable (HostKey) -> Bool
  ) throws {
    let address = try SFTPAddress.parse(url)
    guard let username = address.username, !username.isEmpty else {
      throw UmbelError.sourceUnavailable(detail: "address has no user name")
    }
    var settings = SFTPReader.Settings(
      address: address, username: username, password: address.password, privateKeyFile: nil,
      publicKeyFile: nil, keyPassphrase: nil, connectTimeout: configuration.connectTimeout,
      stallTimeout: configuration.stallTimeout, trust: hostKeyVerifier)
    switch configuration.authentication {
    case .password(let password): settings.password = password
    case .privateKey(let file, let publicKey, let passphrase):
      settings.privateKeyFile = file.path
      settings.publicKeyFile = publicKey?.path
      settings.keyPassphrase = passphrase
    case nil: break
    }
    guard settings.password != nil || settings.privateKeyFile != nil else {
      throw UmbelError.sourceUnavailable(detail: "no way to authenticate was given")
    }
    file = UmbelBlockingFileSource(reader: SFTPReader(settings: settings))
  }

  /// A verifier that trusts exactly these keys, given as OpenSSH prints them
  /// (`SHA256:…`; the digest alone in base 64 is taken too).
  public static func trusting(fingerprints: [String]) -> @Sendable (HostKey) -> Bool {
    let trusted = Set(fingerprints.map { $0.hasPrefix("SHA256:") ? String($0.dropFirst(7)) : $0 })
    return { key in trusted.contains(String(key.fingerprint.dropFirst(7))) }
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

  /// The libraries this module brings, for an app to acknowledge: libssh2
  /// and the OpenSSL it is linked with.
  public static var thirdPartyNotices: [UmbelThirdPartyNotice] {
    let entries: [(name: String, version: String, license: String, file: String)] = [
      ("libssh2", "1.11.1", "BSD-3-Clause", "libssh2"),
      ("OpenSSL", "3.5.9", "Apache-2.0", "OpenSSL"),
    ]
    return entries.map { entry in
      guard let url = Bundle.module.url(forResource: entry.file, withExtension: "txt", subdirectory: "Texts"),
            let text = try? String(contentsOf: url, encoding: .utf8)
      else {
        preconditionFailure("Missing bundled license text for \(entry.name)")
      }
      return UmbelThirdPartyNotice(name: entry.name, version: entry.version, license: entry.license, text: text)
    }
  }
}
