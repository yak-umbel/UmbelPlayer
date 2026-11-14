import Foundation

/// Bytes already in memory, served as a random-access source.
///
/// For content the player has read whole and prepared itself — an external
/// subtitle file after conversion to UTF-8 — so it can go through the same
/// demuxer as everything else.
internal struct MemorySource: UmbelRandomAccessSource {
  private let data: Data

  internal init(data: Data) {
    self.data = data
  }

  var contentLength: Int64? { get async { Int64(data.count) } }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard offset >= 0, offset < Int64(data.count), maxLength > 0 else { return Data() }
    let start = data.startIndex + Int(offset)
    let end = min(start + maxLength, data.endIndex)
    return data.subdata(in: start..<end)
  }

  func invalidate() async {}
}
