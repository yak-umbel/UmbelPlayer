import Foundation

/// A local file.
///
/// An actor to serialise access to the file handle, whose read position is
/// state, while the protocol promises stateless reads at offsets. An
/// implementation that is truly stateless (with pread, say) needs no actor.
public actor UmbelFileSource: UmbelRandomAccessSource {
  private let handle: FileHandle
  private let length: Int64
  private var isInvalidated = false

  public init(url: URL) throws {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let size = attributes[.size] as? NSNumber else {
        throw UmbelError.sourceUnavailable(detail: "cannot read the file size: \(url.path)")
      }
      self.handle = try FileHandle(forReadingFrom: url)
      self.length = size.int64Value
    } catch let error as UmbelError {
      throw error
    } catch {
      throw UmbelError.sourceUnavailable(detail: "cannot open the file: \(UmbelError.detail(for: error))")
    }
  }

  public var contentLength: Int64? { length }

  public func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard !isInvalidated else { throw UmbelError.interrupted }
    guard offset >= 0, maxLength > 0 else { return Data() }
    guard offset < length else { return Data() }
    do {
      try handle.seek(toOffset: UInt64(offset))
      return try handle.read(upToCount: maxLength) ?? Data()
    } catch {
      throw UmbelError.sourceUnavailable(detail: "reading failed: \(UmbelError.detail(for: error))")
    }
  }

  public func invalidate() async {
    guard !isInvalidated else { return }
    isInvalidated = true
    try? handle.close()
  }
}
