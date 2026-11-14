import XCTest
@testable import UmbelCore

/// The sites hosts play from want their own headers — a Referer most often —
/// on every request, the length query included.
final class HTTPHeaderTests: XCTestCase {
  private let url = URL(string: "https://origin.invalid/media.bin")!

  func testTheHeadersGoWithEveryRequest() async throws {
    let source = UmbelHTTPSource(
      url: url, headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
    let data = try await source.read(offset: 10, maxLength: 4)
    XCTAssertEqual(Array(data), [10, 11, 12, 13])
  }

  /// Byte ranges count the bytes as sent: of a compressed response, the
  /// compressed ones. Every request asks for the content as it is, so its
  /// length and offsets are the content's own.
  func testRangesAreOfTheContentAsItIs() async throws {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/encoded")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
    let data = try await source.read(offset: 100, maxLength: 4)
    XCTAssertEqual(Array(data), [100, 101, 102, 103])
  }

  /// A host's own headers do not undo it.
  func testAHostsAcceptEncodingDoesNotUndoIt() async throws {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/encoded")!,
      headers: HeaderStubProtocol.headers.merging(["accept-encoding": "gzip"]) { $1 },
      session: HeaderStubProtocol.session())
    let data = try await source.read(offset: 100, maxLength: 4)
    XCTAssertEqual(Array(data), [100, 101, 102, 103])
  }

  func testWithoutThemTheServerRefuses() async {
    let source = UmbelHTTPSource(url: url, session: HeaderStubProtocol.session())
    let length = await source.contentLength
    XCTAssertNil(length)
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("a 403 is not data")
    } catch {}
  }

  /// Relative addresses in a playlist resolve against where it was found,
  /// which after a redirect is not where it was asked for.
  func testTheLocationIsWhereTheContentWasFound() async throws {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/moved")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let before = await source.location
    XCTAssertEqual(before.absoluteString, "https://origin.invalid/moved")
    _ = try await source.read(offset: 0, maxLength: 4)
    let after = await source.location
    XCTAssertEqual(after.absoluteString, "https://cdn.invalid/media.bin")
  }

  /// The length comes with the first response, on the connection the first
  /// read goes on to use: one request for both, and no HEAD — a request some
  /// servers, and some local proxies, answer wrongly or not at all.
  func testTheLengthAndTheFirstReadTakeOneRequest() async throws {
    let url = URL(string: "https://origin.invalid/one-request.bin")!
    let source = UmbelHTTPSource(
      url: url, headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
    let data = try await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(Array(data), [0, 1, 2, 3])
    let asked = HeaderStubProtocol.requests.filter { $0.hasSuffix("/one-request.bin") }
    XCTAssertEqual(asked, ["GET /one-request.bin"])
  }

  /// Asked once reading has begun elsewhere, the length is that
  /// connection's: no request of its own.
  func testTheLengthAfterAReadElsewhereNeedsNoRequest() async throws {
    let url = URL(string: "https://origin.invalid/read-first.bin")!
    let source = UmbelHTTPSource(
      url: url, headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    _ = try await source.read(offset: 100, maxLength: 4)
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
    let asked = HeaderStubProtocol.requests.filter { $0.hasSuffix("/read-first.bin") }
    XCTAssertEqual(asked, ["GET /read-first.bin"])
  }
}
