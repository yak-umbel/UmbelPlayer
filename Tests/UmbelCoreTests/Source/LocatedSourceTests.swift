import XCTest
@testable import UmbelCore

/// A playlist names its segments by address; they are opened the way the
/// playlist was, headers and all. Wrappers pass the ability on.
final class LocatedSourceTests: XCTestCase {
  private let url = URL(string: "https://origin.invalid/media.bin")!

  func testTheHTTPSourceIsItsOwn() async {
    let source = UmbelHTTPSource(url: url, session: HeaderStubProtocol.session())
    let located = await source.locatedSource
    let location = await located?.location
    XCTAssertEqual(location, url)
  }

  func testWrappersPassOnTheOneTheyWrap() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocatedSourceTests-\(UUID().uuidString)")
    let cache = try UmbelDiskCache(directory: folder, capacity: 1 << 20)
    addTeardownBlock {
      await cache.close()
      try? FileManager.default.removeItem(at: folder)
    }
    let wrapped = UmbelBufferedSource(wrapping: UmbelDiskCacheSource(
      wrapping: UmbelHTTPSource(url: url, session: HeaderStubProtocol.session()),
      key: "k", cache: cache))
    let located = await wrapped.locatedSource
    let location = await located?.location
    XCTAssertEqual(location, url)
  }

  func testAFileHasNone() async throws {
    let located = await (try UmbelFileSource(url: URL(fileURLWithPath: #filePath))).locatedSource
    XCTAssertNil(located)
  }

  func testAnotherAddressIsOpenedWithTheSameHeaders() async throws {
    let source = UmbelHTTPSource(
      url: url, headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let other = await source.source(for: URL(string: "https://origin.invalid/other.bin")!)
    let data = try await other.read(offset: 0, maxLength: 2)
    XCTAssertEqual(Array(data), [0, 1], "a 403 without the Referer")
  }
}
