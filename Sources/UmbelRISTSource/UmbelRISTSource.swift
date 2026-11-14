import Foundation
import LibRIST
import UmbelCore

/// A live stream over RIST, played as the bytes of the transport stream it
/// carries: `rist://host:port`, the player the caller, the sender the listener
/// (`ristsender` with `rist://@host:port`, or any sender that waits for its
/// receivers).
///
/// RIST is built for video over a network that loses packets, as SRT is: the
/// receiver asks again for what is missing, within a buffer of milliseconds
/// (`buffer`, 1000 unless said). A stream may be encrypted with a
/// pre-shared passphrase (`secret`, AES-256 unless `aes-type=128`). RIST does
/// not check the passphrase: a wrong one gives bytes that are not the stream,
/// not an error.
///
/// SRP, the exchange of a passphrase by user name and password, is not
/// offered: the options for it are refused.
///
/// Read once and in order, so the session reports it cannot seek. A stream
/// that is cut is an error, not something to carry on from; the host decides
/// whether to open it again. So is a stream that ends: RIST does not say
/// whether the sender finished or was lost, and for a live stream the second
/// is what must be told. A sender that carries several streams in one is not
/// told apart: the payloads of all come out in the order they arrive.
///
/// The connection is librist's own, so it does not follow the system's proxy
/// settings or App Transport Security. An error never carries the address or
/// the passphrase.
public actor UmbelRISTSource: UmbelStreamingSource {
  /// The RIST profile to receive in (VSF TR-06-2 or TR-06-3). The Simple
  /// profile (TR-06-1) is not offered: its sender pushes to the address of a
  /// receiver that waits, which a caller is not.
  public enum Profile: Sendable {
    /// Tunnelling, encryption, one port: the profile most senders speak.
    case main
    /// The Main profile with larger sequence numbers and more.
    case advanced

    var library: rist_profile {
      switch self {
      case .main: return RIST_PROFILE_MAIN
      case .advanced: return RIST_PROFILE_ADVANCED
      }
    }
  }

  public struct Configuration: Sendable {
    /// How long connecting may take: until the first data arrives, which is
    /// after the sender has been reached and the buffer has filled.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for data before the stream counts as lost.
    public var stallTimeout: TimeInterval
    public var profile: Profile
    /// The recovery buffer, in milliseconds (1 to 60000); also `?buffer=`,
    /// and this wins. More makes for fewer losses and a later start.
    public var buffer: Int?
    /// The pre-shared passphrase (1 to 127 bytes); also `?secret=`, and this wins.
    public var secret: String?
    /// 128 or 256; also `?aes-type=`, and this wins.
    public var aesBits: Int?

    public init(
      connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, profile: Profile = .main,
      buffer: Int? = nil, secret: String? = nil, aesBits: Int? = nil
    ) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.profile = profile
      self.buffer = buffer
      self.secret = secret
      self.aesBits = aesBits
    }
  }

  private let stream: UmbelBlockingStreamSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `rist`, and
  /// `sourceUnavailable` for an address with no host or port, one that would
  /// make the player listen, an option that is not allowed or not valid.
  /// Nothing is opened until the first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    var address = try RISTAddress.parse(url)
    if let buffer = configuration.buffer { try address.set("buffer", String(buffer)) }
    if let secret = configuration.secret { try address.set("secret", secret) }
    if let bits = configuration.aesBits { try address.set("aes-type", String(bits)) }
    stream = UmbelBlockingStreamSource(
      reader: RISTReader(
        address: address, profile: configuration.profile, connectTimeout: configuration.connectTimeout,
        stallTimeout: configuration.stallTimeout))
  }

  /// A live stream has no length.
  public var contentLength: Int64? { nil }

  public func readNext(maxLength: Int) async throws -> Data {
    try await stream.readNext(maxLength: maxLength)
  }

  public func invalidate() async {
    await stream.invalidate()
  }

  /// The libraries this module brings, for an app to acknowledge: librist,
  /// and the three libraries whose source is compiled into it.
  public static var thirdPartyNotices: [UmbelThirdPartyNotice] {
    let entries: [(name: String, version: String, license: String, file: String)] = [
      ("librist", "0.2.20", "BSD-2-Clause", "librist"),
      ("Mbed TLS", "3.6.6", "Apache-2.0", "mbedtls"),
      ("lz4", "1.10.0", "BSD-2-Clause", "lz4"),
      ("cJSON", "1.7.13", "MIT", "cJSON"),
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
