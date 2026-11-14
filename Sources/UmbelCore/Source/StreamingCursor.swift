import Foundation

/// The cursor for streaming sources. The source keeps its own position;
/// this passes reads on and refuses seeks.
internal actor StreamingCursor: ByteCursor {
  private let source: any UmbelStreamingSource

  internal nonisolated var canSeek: Bool { false }

  internal init(source: any UmbelStreamingSource) {
    self.source = source
  }

  internal var totalLength: Int64? {
    get async { await source.contentLength }
  }

  internal func read(maxLength: Int) async throws -> Data {
    try await source.readNext(maxLength: maxLength)
  }

  internal func seek(toOffset offset: Int64) async throws {
    throw UmbelError.seekUnsupported
  }
}
