import Foundation
import UmbelFFmpegSupport

/// A file on an FTP server, read from anywhere: `ftp://host/path`, with
/// `user:password@` in the address if the server wants a login (anonymous
/// otherwise).
///
/// Random access, so the session can seek: a read from where the last one
/// ended goes on over the same transfer, and a read from elsewhere asks the
/// server to start there (`REST`), which makes a connection again.
///
/// FTP is not encrypted: the login and the file cross the network as they
/// are. The connection is FFmpeg's own, so it does not follow the system's
/// proxy settings or App Transport Security. Nothing is retried; a read that
/// fails says so, and the host decides.
///
/// A read that is cancelled gives up at once, and the connection, left in a
/// state nobody knows, is closed; the next read opens one again. An error
/// never carries the address, which holds the password.
public actor UmbelFTPSource: UmbelRandomAccessSource {
  public struct Configuration: Sendable {
    /// How long connecting and logging in may take.
    public var connectTimeout: TimeInterval
    /// How long a read may wait for bytes before the transfer counts as lost.
    public var stallTimeout: TimeInterval

    public init(connectTimeout: TimeInterval = 15, stallTimeout: TimeInterval = 20) {
      self.connectTimeout = connectTimeout
      self.stallTimeout = stallTimeout
    }
  }

  private let file: UmbelBlockingFileSource

  /// Throws `UmbelError.unsupportedScheme` for any scheme but `ftp`. Nothing
  /// is opened until the first read.
  public init(url: URL, configuration: Configuration = Configuration()) throws {
    let scheme = url.scheme?.lowercased() ?? ""
    guard scheme == "ftp" else { throw UmbelError.unsupportedScheme(scheme) }
    let reader = FFmpegProtocolReader(
      address: url.absoluteString,
      configuration: .init(
        allowedProtocols: ["ftp", "tcp"], connectTimeout: configuration.connectTimeout,
        stallTimeout: configuration.stallTimeout))
    file = UmbelBlockingFileSource(reader: FTPFileReader(reader: reader))
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
}

/// FFmpeg's FTP, as a file that blocking calls read: where the last read
/// ended is remembered, and a read from elsewhere repositions first.
private final class FTPFileReader: UmbelBlockingFileReader, @unchecked Sendable {
  private let reader: FFmpegProtocolReader
  /// Touched on the source's thread only, as every call but giving up is.
  private var position: Int64 = 0

  init(reader: FFmpegProtocolReader) { self.reader = reader }

  func open() throws {
    do {
      try reader.open()
      position = 0
    } catch {
      throw NetworkStreamPump.umbelError(for: error)
    }
  }

  func size() -> Int64? { reader.knownSize() }

  func read(offset: Int64, maxLength: Int) throws -> Data {
    do {
      if position != offset {
        try reader.seek(to: offset)
        position = offset
      }
      let data = try reader.read(maxLength: maxLength)
      position += Int64(data.count)
      return data
    } catch {
      throw NetworkStreamPump.umbelError(for: error)
    }
  }

  func abandonCurrentCall() { reader.abandonCurrentCall() }
  func requestInterrupt() { reader.requestInterrupt() }
  func close() { reader.close() }
}
