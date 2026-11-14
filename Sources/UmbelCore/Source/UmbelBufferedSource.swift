import Foundation

/// Adds a block cache to a random-access source.
///
/// The problem it solves is specific: the demuxer reads a few tens of KiB at
/// a time, on a network source a round trip each. Fetching by blocks and
/// cutting small requests out of them, reading in order rarely reaches the
/// source beneath.
///
/// A **decorator**: it wraps any random-access source and is one itself, so
/// using it changes no existing code, only one more wrapping at
/// construction.
///
/// It goes to the source at most once a read, from where the read starts,
/// and hands over what came back even if short. Filling a whole block before
/// answering held up the first byte of a network read by the block's
/// download time; a demuxer takes short reads and simply reads on.
public actor UmbelBufferedSource: UmbelRandomAccessSource {
  private let inner: any UmbelRandomAccessSource
  private let chunkSize: Int

  private var chunkOffset: Int64 = -1
  private var chunk = Data()
  private var isInvalidated = false

  public init(wrapping inner: any UmbelRandomAccessSource, chunkSize: Int = 1024 * 1024) {
    self.inner = inner
    self.chunkSize = max(1, chunkSize)
  }

  public var locatedSource: (any UmbelLocatedSource)? {
    get async { await inner.locatedSource }
  }

  public var contentLength: Int64? {
    get async { await inner.contentLength }
  }

  public func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard !isInvalidated else { throw UmbelError.interrupted }
    guard offset >= 0, maxLength > 0 else { return Data() }

    var result = Data()
    var cursor = offset
    var remaining = maxLength

    while remaining > 0 {
      if !contains(cursor) {
        // Once a read has something, it does not wait on the source again.
        guard result.isEmpty else { break }
        try await fetchChunk(at: cursor)
      }
      let piece = slice(at: cursor, maxLength: remaining)
      if piece.isEmpty { break }
      result.append(piece)
      cursor += Int64(piece.count)
      remaining -= piece.count
    }
    return result
  }

  public func invalidate() async {
    isInvalidated = true
    chunk = Data()
    chunkOffset = -1
    await inner.invalidate()
  }

  /// As many bytes from `offset` as the cache holds.
  private func slice(at offset: Int64, maxLength: Int) -> Data {
    guard contains(offset) else { return Data() }

    let start = Int(offset - chunkOffset)
    let available = chunk.count - start
    guard available > 0 else { return Data() }
    let count = min(maxLength, available)
    return chunk.subdata(in: start..<(start + count))
  }

  private func contains(_ offset: Int64) -> Bool {
    chunkOffset >= 0 && offset >= chunkOffset && offset < chunkOffset + Int64(chunk.count)
  }

  /// Up to a chunk from `offset`, whatever the source has for it now. From
  /// the offset rather than an aligned one: aligned, a network source would
  /// be asked again from where it has already passed, and have to start
  /// over.
  private func fetchChunk(at offset: Int64) async throws {
    let data = try await inner.read(offset: offset, maxLength: chunkSize)
    chunkOffset = data.isEmpty ? -1 : offset
    chunk = data
  }
}
