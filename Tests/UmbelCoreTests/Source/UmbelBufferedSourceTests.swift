import XCTest
@testable import UmbelCore

/// A fake that keeps count: byte n is n % 256, and it counts its reads and
/// where they start. It can hand out short reads.
private actor CountingSource: UmbelRandomAccessSource {
  private let length: Int64
  private let largestRead: Int
  private var readCount = 0
  private(set) var offsets: [Int64] = []

  init(length: Int64, largestRead: Int = .max) {
    self.length = length
    self.largestRead = largestRead
  }

  var contentLength: Int64? { length }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    readCount += 1
    offsets.append(offset)
    guard offset < length else { return Data() }
    let count = Int(min(Int64(min(maxLength, largestRead)), length - offset))
    return Data((0..<count).map { UInt8((Int(offset) + $0) % 256) })
  }

  func invalidate() async {}
  func reads() -> Int { readCount }
}

final class UmbelBufferedSourceTests: XCTestCase {
  func testReadReturnsSameBytesAsUnderlyingSource() async throws {
    let inner = CountingSource(length: 10_000)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    let data = try await buffered.read(offset: 100, maxLength: 4)
    XCTAssertEqual(Array(data), [100, 101, 102, 103])
  }

  func testSequentialReadsHitTheCache() async throws {
    let inner = CountingSource(length: 100_000)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 4096)

    // 16 reads of 256 bytes in order, all within one 4096-byte block.
    for index in 0..<16 {
      _ = try await buffered.read(offset: Int64(index * 256), maxLength: 256)
    }

    let reads = await inner.reads()
    XCTAssertEqual(reads, 1, "16 small requests make a single read beneath")
  }

  func testCrossingChunkBoundaryFetchesNextChunk() async throws {
    let inner = CountingSource(length: 100_000)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    let data = try await buffered.read(offset: 1000, maxLength: 48)
    XCTAssertEqual(data.count, 48)
    XCTAssertEqual(Array(data.prefix(2)), [UInt8(1000 % 256), UInt8(1001 % 256)])
    XCTAssertEqual(Array(data.suffix(1)), [UInt8(1047 % 256)])
  }

  func testReadPastEndReturnsEmpty() async throws {
    let inner = CountingSource(length: 500)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    let data = try await buffered.read(offset: 500, maxLength: 16)
    XCTAssertTrue(data.isEmpty)
  }

  func testReadNearEndIsTruncated() async throws {
    let inner = CountingSource(length: 500)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    let data = try await buffered.read(offset: 490, maxLength: 100)
    XCTAssertEqual(data.count, 10)
  }

  func testContentLengthPassesThrough() async {
    let inner = CountingSource(length: 777)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 128)
    let length = await buffered.contentLength
    XCTAssertEqual(length, 777)
  }

  func testInvalidateDropsCacheAndRejectsReads() async throws {
    let inner = CountingSource(length: 10_000)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    _ = try await buffered.read(offset: 0, maxLength: 16)
    await buffered.invalidate()
    do {
      _ = try await buffered.read(offset: 0, maxLength: 16)
      XCTFail("reading after invalidation throws")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .interrupted)
    }
  }

  /// A read goes to the source at most once and hands on what came back,
  /// short or not, rather than waiting on the source again to fill it.
  func testAReadGoesToTheSourceAtMostOnce() async throws {
    let inner = CountingSource(length: 10_000, largestRead: 100)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    let data = try await buffered.read(offset: 0, maxLength: 1_000)
    XCTAssertEqual(data.count, 100)
    let reads = await inner.reads()
    XCTAssertEqual(reads, 1)
  }

  /// From where the read starts, not an aligned block: a network source
  /// asked again from before where it has got to would have to start over.
  func testFetchesFromWhereTheReadStarts() async throws {
    let inner = CountingSource(length: 10_000)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    _ = try await buffered.read(offset: 1_000, maxLength: 10)
    let offsets = await inner.offsets
    XCTAssertEqual(offsets, [1_000])
  }

  func testBackwardSeekRefetches() async throws {
    let inner = CountingSource(length: 100_000)
    let buffered = UmbelBufferedSource(wrapping: inner, chunkSize: 1024)
    _ = try await buffered.read(offset: 0, maxLength: 16)
    _ = try await buffered.read(offset: 50_000, maxLength: 16)
    let data = try await buffered.read(offset: 0, maxLength: 4)
    XCTAssertEqual(Array(data), [0, 1, 2, 3], "reading back gets the right bytes too")
  }
}
