import XCTest
@testable import UmbelCore

/// A stateless random-access fake: byte n is n % 256.
private actor FakeRandomAccessSource: UmbelRandomAccessSource {
  private let length: Int64

  init(length: Int64) { self.length = length }

  var contentLength: Int64? { length }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard offset < length else { return Data() }
    let count = Int(min(Int64(maxLength), length - offset))
    return Data((0..<count).map { UInt8((Int(offset) + $0) % 256) })
  }

  func invalidate() async {}
}

/// A fake that reads in order only, keeping its own cursor.
private actor FakeStreamingSource: UmbelStreamingSource {
  private let bytes: [UInt8]
  private var position = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  var contentLength: Int64? { nil }

  func readNext(maxLength: Int) async throws -> Data {
    guard position < bytes.count else { return Data() }
    let end = min(position + maxLength, bytes.count)
    defer { position = end }
    return Data(bytes[position..<end])
  }

  func invalidate() async {}
}

final class RandomAccessCursorTests: XCTestCase {
  func testSequentialReadsAdvancePosition() async throws {
    let cursor = RandomAccessCursor(source: FakeRandomAccessSource(length: 100))
    let first = try await cursor.read(maxLength: 4)
    let second = try await cursor.read(maxLength: 4)
    XCTAssertEqual(Array(first), [0, 1, 2, 3])
    XCTAssertEqual(Array(second), [4, 5, 6, 7])
  }

  func testReadStopsAtEnd() async throws {
    let cursor = RandomAccessCursor(source: FakeRandomAccessSource(length: 6))
    let all = try await cursor.read(maxLength: 10)
    XCTAssertEqual(all.count, 6)
    let past = try await cursor.read(maxLength: 10)
    XCTAssertTrue(past.isEmpty)
  }

  func testSeekMovesPosition() async throws {
    let cursor = RandomAccessCursor(source: FakeRandomAccessSource(length: 100))
    try await cursor.seek(toOffset: 50)
    let data = try await cursor.read(maxLength: 3)
    XCTAssertEqual(Array(data), [50, 51, 52])
  }

  func testSeekBackwardsWorks() async throws {
    let cursor = RandomAccessCursor(source: FakeRandomAccessSource(length: 100))
    _ = try await cursor.read(maxLength: 40)
    try await cursor.seek(toOffset: 2)
    let data = try await cursor.read(maxLength: 2)
    XCTAssertEqual(Array(data), [2, 3])
  }

  func testCanSeekIsTrue() {
    let cursor = RandomAccessCursor(source: FakeRandomAccessSource(length: 1))
    XCTAssertTrue(cursor.canSeek)
  }

  func testTotalLengthComesFromSource() async {
    let cursor = RandomAccessCursor(source: FakeRandomAccessSource(length: 77))
    let length = await cursor.totalLength
    XCTAssertEqual(length, 77)
  }
}

final class StreamingCursorTests: XCTestCase {
  func testReadForwardsToSource() async throws {
    let cursor = StreamingCursor(source: FakeStreamingSource(bytes: [9, 8, 7, 6]))
    let first = try await cursor.read(maxLength: 2)
    let second = try await cursor.read(maxLength: 2)
    XCTAssertEqual(Array(first), [9, 8])
    XCTAssertEqual(Array(second), [7, 6])
  }

  func testReadAtEndReturnsEmpty() async throws {
    let cursor = StreamingCursor(source: FakeStreamingSource(bytes: [1]))
    _ = try await cursor.read(maxLength: 4)
    let past = try await cursor.read(maxLength: 4)
    XCTAssertTrue(past.isEmpty)
  }

  func testCanSeekIsFalse() {
    let cursor = StreamingCursor(source: FakeStreamingSource(bytes: []))
    XCTAssertFalse(cursor.canSeek)
  }

  func testSeekThrowsSeekUnsupported() async {
    let cursor = StreamingCursor(source: FakeStreamingSource(bytes: [1, 2, 3]))
    do {
      try await cursor.seek(toOffset: 1)
      XCTFail("seeking a streaming cursor throws")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .seekUnsupported)
    } catch {
      XCTFail("expected UmbelError.seekUnsupported, got \(error)")
    }
  }

  func testTotalLengthIsNil() async {
    let cursor = StreamingCursor(source: FakeStreamingSource(bytes: [1]))
    let length = await cursor.totalLength
    XCTAssertNil(length)
  }
}
