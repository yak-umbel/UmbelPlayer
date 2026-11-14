import Foundation

/// Any source as "read in order, seek if you can": the shape custom I/O
/// wants.
///
/// The one place live and on-demand content part; demuxing, reading packets
/// and mapping tracks above it are shared. They part for a physical reason:
/// a live connection cannot be read at random.
internal protocol ByteCursor: Sendable {
  /// Total bytes; nil if unknown.
  var totalLength: Int64? { get async }

  /// Whether it can seek. Fixed, so not async.
  nonisolated var canSeek: Bool { get }

  /// Reads on in order. Empty means the end.
  func read(maxLength: Int) async throws -> Data

  /// Seeks to an absolute offset. Throws `UmbelError.seekUnsupported` when
  /// `canSeek` is false.
  func seek(toOffset offset: Int64) async throws
}
