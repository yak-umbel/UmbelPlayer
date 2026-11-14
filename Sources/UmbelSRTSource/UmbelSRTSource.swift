import Foundation
import UmbelCore

/// A live stream over SRT, played as the bytes of the transport stream it
/// carries: `srt://host:port`, the player the caller, the sender the listener.
///
/// SRT is built for video over a network that loses packets: the sender keeps
/// what it has sent for as long as the latency asks, and the receiver asks for
/// what it is missing. A stream may be encrypted with a passphrase; it is
/// checked, and a wrong one is refused at the connection.
///
/// Read once and in order, so the session reports it cannot seek. A stream
/// that is cut is an error, not something to carry on from; the host decides
/// whether to open it again. So is a stream that ends: SRT does not say
/// whether the sender finished or was lost, and for a live stream the second
/// is what must be told.
///
/// The connection is SRT's own, so it does not follow the system's proxy
/// settings or App Transport Security. An error never carries the address or
/// the passphrase.
public actor UmbelSRTSource: UmbelStreamingSource {
  public struct Configuration: Sendable {
    /// How long connecting may take, the exchange with the sender included.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for a message before the stream counts as lost.
    public var stallTimeout: TimeInterval
    /// Milliseconds the receiver waits for what is missing before it goes on
    /// without it; nil for SRT's own default. Also takes `?latency=` in the
    /// address; this wins.
    public var latency: Int?
    /// What the sender is told it is being asked for (`?streamid=`).
    public var streamID: String?
    /// 10 to 79 characters; also `?passphrase=`, and this wins. Checked at
    /// the connection: a stream with a secret is refused without it.
    public var passphrase: String?

    public init(
      connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20, latency: Int? = nil,
      streamID: String? = nil, passphrase: String? = nil
    ) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
      self.latency = latency
      self.streamID = streamID
      self.passphrase = passphrase
    }
  }

  private let stream: UmbelBlockingStreamSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `srt`, and
  /// `sourceUnavailable` for an address with no port, an option that is not
  /// allowed, or a passphrase of the wrong length. Nothing is opened until the
  /// first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    var address = try SRTAddress.parse(url)
    if let latency = configuration.latency { address.latency = latency }
    if let streamID = configuration.streamID { address.streamID = streamID }
    if let passphrase = configuration.passphrase { address.passphrase = passphrase }
    if let passphrase = address.passphrase, !(10...79).contains(passphrase.utf8.count) {
      throw UmbelError.sourceUnavailable(detail: "SRT passphrase must be 10 to 79 characters")
    }
    stream = UmbelBlockingStreamSource(
      reader: SRTReader(
        address: address, connectTimeout: configuration.connectTimeout, stallTimeout: configuration.stallTimeout))
  }

  /// A live stream has no length.
  public var contentLength: Int64? { nil }

  public func readNext(maxLength: Int) async throws -> Data {
    try await stream.readNext(maxLength: maxLength)
  }

  public func invalidate() async {
    await stream.invalidate()
  }

  /// The libraries this module brings, for an app to acknowledge: SRT and
  /// the OpenSSL it is linked with.
  public static var thirdPartyNotices: [UmbelThirdPartyNotice] {
    let entries: [(name: String, version: String, license: String, file: String)] = [
      ("SRT", "1.5.7", "MPL-2.0", "SRT"),
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
