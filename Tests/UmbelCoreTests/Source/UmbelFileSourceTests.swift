import XCTest
@testable import UmbelCore

final class UmbelFileSourceTests: XCTestCase {
  private var url: URL!

  override func setUpWithError() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("umbel-file-source-\(UUID().uuidString).bin")
    // 0, 1, 2, …, 255 — each byte's value is its offset, so a wrong position
    // shows at a glance.
    try Data((0..<256).map { UInt8($0) }).write(to: url)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: url)
  }

  func testContentLengthMatchesFileSize() async throws {
    let source = try UmbelFileSource(url: url)
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
  }

  func testReadReturnsBytesAtRequestedOffset() async throws {
    let source = try UmbelFileSource(url: url)
    let data = try await source.read(offset: 10, maxLength: 4)
    XCTAssertEqual(Array(data), [10, 11, 12, 13])
  }

  func testReadIsStatelessAcrossCalls() async throws {
    let source = try UmbelFileSource(url: url)
    _ = try await source.read(offset: 200, maxLength: 8)
    // Reading the same place again gives the same bytes: statelessness is
    // the protocol's core contract.
    let first = try await source.read(offset: 10, maxLength: 4)
    let second = try await source.read(offset: 10, maxLength: 4)
    XCTAssertEqual(Array(first), [10, 11, 12, 13])
    XCTAssertEqual(first, second)
  }

  func testReadNearEndReturnsFewerBytes() async throws {
    let source = try UmbelFileSource(url: url)
    let data = try await source.read(offset: 250, maxLength: 100)
    XCTAssertEqual(data.count, 6)
    XCTAssertEqual(Array(data), [250, 251, 252, 253, 254, 255])
  }

  func testReadPastEndReturnsEmpty() async throws {
    let source = try UmbelFileSource(url: url)
    let data = try await source.read(offset: 256, maxLength: 16)
    XCTAssertTrue(data.isEmpty)
  }

  func testReadAfterInvalidateThrowsInterrupted() async throws {
    let source = try UmbelFileSource(url: url)
    await source.invalidate()
    do {
      _ = try await source.read(offset: 0, maxLength: 1)
      XCTFail("reading after invalidate throws")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .interrupted)
    }
  }

  func testInvalidateIsIdempotent() async throws {
    let source = try UmbelFileSource(url: url)
    await source.invalidate()
    await source.invalidate()
  }

  /// Named by the system error's domain and code, not its words, which
  /// follow the device's language.
  func testAMissingFileIsNamedByItsErrorCode() {
    let missing = url.appendingPathExtension("nope")
    XCTAssertThrowsError(try UmbelFileSource(url: missing)) { error in
      guard case UmbelError.sourceUnavailable(let detail) = error else {
        return XCTFail("expected sourceUnavailable, got \(error)")
      }
      XCTAssertEqual(detail, "cannot open the file: NSCocoaErrorDomain error 260")
    }
  }

  func testMissingFileThrowsSourceUnavailable() {
    let missing = url.appendingPathExtension("nope")
    XCTAssertThrowsError(try UmbelFileSource(url: missing)) { error in
      guard case UmbelError.sourceUnavailable = error else {
        return XCTFail("expected sourceUnavailable, got \(error)")
      }
    }
  }
}
