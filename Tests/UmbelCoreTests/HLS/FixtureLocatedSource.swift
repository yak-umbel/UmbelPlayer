import Foundation
@testable import UmbelCore

/// Serves a fixture directory as a server would, by address: located
/// sources over file URLs. Names in `failing` cannot be had, as segments a
/// server lost; every address opened is logged.
final class FixtureServer: @unchecked Sendable {
  let failing: Set<String>
  private let lock = NSLock()
  private var log: [String] = []

  init(failing: Set<String> = []) {
    self.failing = failing
  }

  var opened: [String] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func note(_ name: String) {
    lock.lock()
    log.append(name)
    lock.unlock()
  }

  func source(_ url: URL) -> FixtureLocatedSource {
    FixtureLocatedSource(url: url, server: self)
  }
}

actor FixtureLocatedSource: UmbelLocatedSource {
  private let url: URL
  private let server: FixtureServer

  init(url: URL, server: FixtureServer) {
    self.url = url
    self.server = server
  }

  var location: URL { url }

  func source(for url: URL) -> any UmbelRandomAccessSource {
    server.note(url.lastPathComponent)
    return FixtureLocatedSource(url: url, server: server)
  }

  var contentLength: Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
  }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    if server.failing.contains(url.lastPathComponent) {
      throw UmbelError.sourceUnavailable(detail: "404")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    return try handle.read(upToCount: maxLength) ?? Data()
  }

  func invalidate() {}
}
