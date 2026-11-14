import Foundation

/// Owns the request's I/O, including resources opened by a playlist.
/// Cancellation releases callers even when a custom read ignores cancellation.
/// Such a read can finish later; its task holds only its source, not the demuxer.
internal actor ThumbnailSourceScope {
  private var ended = false
  private var sources: [any UmbelSource] = []
  private var pending: [UUID: @Sendable () -> Void] = [:]

  func perform<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    guard !ended else { throw CancellationError() }
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let task = Task {
        let result: Result<Value, any Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        if self.pending.removeValue(forKey: id) != nil {
          continuation.resume(with: result)
        }
      }
      pending[id] = { task.cancel(); continuation.resume(throwing: CancellationError()) }
    }
  }

  func own(_ source: any UmbelSource) async throws {
    guard !ended else {
      await source.invalidate()
      throw CancellationError()
    }
    sources.append(source)
  }

  func cancel() {
    ended = true
    let operations = pending.values
    pending.removeAll()
    for cancel in operations { cancel() }
  }

  func close() async {
    cancel()
    let owned = sources
    sources.removeAll()
    for source in owned { await source.invalidate() }
  }
}

internal struct ThumbnailSource: UmbelRandomAccessSource {
  let source: any UmbelRandomAccessSource
  let scope: ThumbnailSourceScope

  var contentLength: Int64? {
    get async { try? await scope.perform { await source.contentLength } }
  }
  var locatedSource: (any UmbelLocatedSource)? {
    get async {
      guard let located = try? await scope.perform({ await source.locatedSource }) else { return nil }
      return ThumbnailLocatedSource(source: located, scope: scope)
    }
  }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    try await scope.perform { try await source.read(offset: offset, maxLength: maxLength) }
  }
  func invalidate() async { await source.invalidate() }
}

private struct ThumbnailLocatedSource: UmbelLocatedSource {
  let source: any UmbelLocatedSource
  let scope: ThumbnailSourceScope

  var contentLength: Int64? {
    get async { await ThumbnailSource(source: source, scope: scope).contentLength }
  }
  var location: URL {
    get async {
      (try? await scope.perform { await source.location }) ?? URL(fileURLWithPath: "/")
    }
  }
  func source(for url: URL) async -> any UmbelRandomAccessSource {
    let child = try? await scope.perform {
      let opened = await source.source(for: url)
      try await scope.own(opened)
      return opened
    }
    // The protocol cannot throw here. A cancelled scope makes its next read
    // throw, so the placeholder is never treated as successful empty media.
    return ThumbnailSource(source: child ?? MemorySource(data: Data()), scope: scope)
  }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    try await scope.perform { try await source.read(offset: offset, maxLength: maxLength) }
  }
  func invalidate() async { await source.invalidate() }
}
