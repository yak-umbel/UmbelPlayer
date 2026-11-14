import Foundation

/// The cursor for random-access sources.
///
/// The position for reading in order lives here alone, not written again in
/// each source (each with bugs of its own).
///
/// Given a window, it reads that part of the source alone, as if it were
/// the whole: offset 0 is the window's first byte.
internal actor RandomAccessCursor: ByteCursor {
  private let source: any UmbelRandomAccessSource
  private let window: Range<Int64>?
  private var position: Int64 = 0
  /// The source's first bytes, already read: served from here, so reading
  /// goes on from where they end — where a network source's connection is.
  private var head = Data()

  internal nonisolated var canSeek: Bool { true }

  internal init(source: any UmbelRandomAccessSource, window: Range<Int64>? = nil) {
    self.source = source
    self.window = window
  }

  internal var totalLength: Int64? {
    get async {
      if let window { return window.upperBound - window.lowerBound }
      return await source.contentLength
    }
  }

  /// The source's first bytes, read already by whoever looked at them.
  internal func hold(_ head: Data) {
    guard window == nil else { return }
    self.head = head
  }

  internal func read(maxLength: Int) async throws -> Data {
    if position < Int64(head.count), maxLength > 0 {
      let start = head.startIndex + Int(position)
      let slice = head[start..<min(head.endIndex, start + maxLength)]
      position += Int64(slice.count)
      return Data(slice)
    }
    var wanted = maxLength
    if let window {
      wanted = Int(min(Int64(maxLength), max(0, window.upperBound - window.lowerBound - position)))
      guard wanted > 0 else { return Data() }
    }
    let data = try await source.read(offset: (window?.lowerBound ?? 0) + position, maxLength: wanted)
    position += Int64(data.count)
    return data
  }

  internal func seek(toOffset offset: Int64) async throws {
    guard offset >= 0 else { throw UmbelError.seekUnsupported }
    position = offset
  }
}
