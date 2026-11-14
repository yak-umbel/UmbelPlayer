import Foundation

/// What every source has.
///
/// Sources are where a host plugs in: the player does not care where bytes
/// come from (a file, the network, a custom protocol, the host's own cache),
/// only that they can be had as agreed.
public protocol UmbelSource: Sendable {
  /// Total bytes; nil for sources of unknown length, such as live ones.
  var contentLength: Int64? { get async }

  /// Releases what is held beneath (connections, file handles). Every read
  /// after that throws `UmbelError.interrupted`. Can be called again; from
  /// the second time on it does nothing.
  func invalidate() async

  /// The source beneath that can open other addresses the way it was
  /// opened, if there is one; see `UmbelLocatedSource`. Wrappers pass on the
  /// one they wrap.
  var locatedSource: (any UmbelLocatedSource)? { get async }
}

extension UmbelSource {
  public var locatedSource: (any UmbelLocatedSource)? {
    get async { self as? any UmbelLocatedSource }
  }
}

/// Random access: local files, HTTP with ranges, a host's block cache.
///
/// Reads are stateless — the same offset always gives the same bytes, so an
/// implementation meets `Sendable` without writing any synchronisation.
public protocol UmbelRandomAccessSource: UmbelSource {
  /// Reads up to `maxLength` bytes at `offset`.
  ///
  /// May return fewer than `maxLength` bytes; empty means the offset is at
  /// the end of the content.
  ///
  /// **Follow cancellation.** The player cancels the task a read is in when
  /// what it would bring is no longer wanted — a seek to somewhere not read
  /// yet, closing — and the read should end then rather than at its own
  /// pace, throwing `UmbelError.interrupted` (or `CancellationError`). Unlike
  /// `invalidate()` this does not close the source: the reads that come
  /// next, from wherever the seek puts them, are served as before. A read
  /// that ignores cancellation costs the seek the wait for it.
  func read(offset: Int64, maxLength: Int) async throws -> Data
}

/// Only in order: live streams, pipes, HTTP without ranges.
///
/// The source holds its own cursor — a connection is stateful to begin with,
/// and pretending otherwise would be awkward.
public protocol UmbelStreamingSource: UmbelSource {
  /// Reads up to `maxLength` bytes in order, moving the cursor on.
  ///
  /// May return fewer than `maxLength` bytes; empty means the stream ended.
  /// A read follows cancellation as `UmbelRandomAccessSource.read` does.
  func readNext(maxLength: Int) async throws -> Data
}

/// A source found at an address that can open the addresses its content
/// refers to — a playlist's segments — the same way: the same request
/// headers, the same session, the same retries.
///
/// A host with networking of its own (a proxy, cookies, signed requests)
/// implements it to have playlists fetched its way.
public protocol UmbelLocatedSource: UmbelRandomAccessSource {
  /// Where the content was found: after any redirects once a read has been
  /// answered, the address asked for before that. Relative addresses in the
  /// content resolve against it.
  var location: URL { get async }
  /// A source for another address, opened the way this one was.
  func source(for url: URL) async -> any UmbelRandomAccessSource
}
