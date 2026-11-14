import Foundation

/// Reads a random-access source through a disk cache: what has been read
/// once is read from disk after that, across plays, and offline.
///
/// A decorator like `UmbelBufferedSource`, and meant to sit under it:
///
///     UmbelBufferedSource(wrapping:
///       UmbelDiskCacheSource(wrapping: UmbelHTTPSource(url: url),
///                            key: url.absoluteString, cache: cache))
///
/// The memory layer asks for a mebibyte from where it reads; this answers up
/// to the end of that block, from disk or from what the source has so far.
///
/// **The key says what counts as the same content.** Sources carry no URL,
/// and even a URL may serve new content — a signed link, a new version. Only
/// the host knows; pass a key that changes when the content does. A length
/// that differs from the one recorded drops what was cached, but content
/// changed at the same length cannot be told apart.
///
/// Live and other streaming sources have no offsets to cache by, and are
/// not cached.
public actor UmbelDiskCacheSource: UmbelRandomAccessSource {
  private let inner: any UmbelRandomAccessSource
  private let key: String
  private let cache: UmbelDiskCache
  private let blockSize: Int

  /// The block being read through from the source, not yet whole.
  private var filling: Filling?
  /// Settled on first use; see `settledLength()`.
  private var length: Int64?
  private var isLengthSettled = false
  private var isInvalidated = false

  public init(wrapping inner: any UmbelRandomAccessSource, key: String, cache: UmbelDiskCache) {
    self.inner = inner
    self.key = key
    self.cache = cache
    self.blockSize = cache.blockSize
  }

  public var locatedSource: (any UmbelLocatedSource)? {
    get async { await inner.locatedSource }
  }

  public var contentLength: Int64? {
    get async { await settledLength() }
  }

  /// Serves up to the end of the block holding `offset` — a short read, as
  /// the protocol allows; the next read carries on.
  ///
  /// A block not on disk is read through from the source as it comes, each
  /// read handing on what the source gave, and written to disk once whole.
  /// Collected whole before answering, a block held up the first byte of a
  /// network read by its download time. Only a block read through from its
  /// start is kept: one a seek lands in the middle of is served but not
  /// written, and caching goes on from the next.
  public func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard !isInvalidated else { throw UmbelError.interrupted }
    guard offset >= 0, maxLength > 0 else { return Data() }
    if let length = await settledLength(), offset >= length { return Data() }

    let index = offset / Int64(blockSize)
    if let block = await cache.block(forKey: key, at: index) {
      let start = Int(offset - index * Int64(blockSize))
      guard start < block.count else { return Data() }
      return block.subdata(in: start..<min(block.count, start + maxLength))
    }
    return try await readThrough(offset: offset, maxLength: maxLength, block: index)
  }

  public func invalidate() async {
    isInvalidated = true
    await inner.invalidate()
  }

  /// The length the source reports, recorded for next time — and checked
  /// against what was recorded before. Unreported, as when offline, the
  /// recorded one stands in.
  private func settledLength() async -> Int64? {
    if isLengthSettled { return length }
    if let reported = await inner.contentLength {
      await cache.setContentLength(reported, forKey: key)
      length = reported
    } else {
      length = await cache.contentLength(forKey: key)
    }
    isLengthSettled = true
    return length
  }

  /// What of the block being filled covers `offset`, or more of it from
  /// the source when `offset` is where the filling has got to.
  private func readThrough(offset: Int64, maxLength: Int, block index: Int64) async throws -> Data {
    let blockStart = index * Int64(blockSize)
    let blockEnd = blockStart + Int64(blockSize)
    if let filling, filling.index == index, filling.covers(offset) {
      return filling.bytes(from: offset, maxLength: maxLength)
    }
    if filling?.index != index || filling?.end != offset {
      filling = Filling(index: index, start: offset)
    }

    let piece = try await inner.read(offset: offset, maxLength: Int(blockEnd - offset))
    if piece.isEmpty {
      // A source that never said how long it is has just said it.
      if length == nil {
        length = offset
        await cache.setContentLength(offset, forKey: key)
      }
      await keepFilling(endingAt: offset)
      return Data()
    }
    filling?.data.append(piece)
    let reachedEnd = length.map { offset + Int64(piece.count) >= $0 } ?? false
    if offset + Int64(piece.count) >= blockEnd || reachedEnd {
      await keepFilling(endingAt: offset + Int64(piece.count))
    }
    return piece.prefix(maxLength)
  }

  /// The filling block is done: offered to the cache, and let go. The
  /// cache takes a block only at its full size, so one entered midway is
  /// not kept; a second read of it comes from the source again.
  private func keepFilling(endingAt end: Int64) async {
    guard let done = filling, done.end == end else { return }
    filling = nil
    if !done.data.isEmpty {
      await cache.store(done.data, forKey: key, at: done.index)
    }
  }
}

/// A block being read through from the source.
private struct Filling {
  let index: Int64
  /// Where in the file the data starts: the block's start, or where a seek
  /// landed in it.
  let start: Int64
  var data = Data()

  var end: Int64 { start + Int64(data.count) }

  func covers(_ offset: Int64) -> Bool { offset >= start && offset < end }

  func bytes(from offset: Int64, maxLength: Int) -> Data {
    let first = Int(offset - start)
    return data.subdata(in: first..<min(data.count, first + maxLength))
  }
}
