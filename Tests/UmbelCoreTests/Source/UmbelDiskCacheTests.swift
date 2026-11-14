import XCTest
@testable import UmbelCore

/// The store under the disk cache source. Blocks of four bytes keep the
/// fixtures readable; the real size is a mebibyte.
final class UmbelDiskCacheTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("UmbelDiskCacheTests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func cache(capacity: Int64 = 1_000) throws -> UmbelDiskCache {
    try UmbelDiskCache(directory: directory, capacity: capacity, blockSize: 4)
  }

  private func block(_ byte: UInt8, count: Int = 4) -> Data {
    Data(repeating: byte, count: count)
  }

  /// The one directory a key's blocks live in.
  private func keyDirectory() throws -> URL {
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    return try XCTUnwrap(entries.first { $0.lastPathComponent.count == 64 })
  }

  func testStoredBlockReadsBack() async throws {
    let cache = try cache()
    await cache.store(block(7), forKey: "a", at: 0)
    let read = await cache.block(forKey: "a", at: 0)
    XCTAssertEqual(read, block(7))
    let cached = await cache.cachedBytes(forKey: "a")
    let used = await cache.usedBytes
    XCTAssertEqual(cached, 4)
    XCTAssertEqual(used, 4)
    let other = await cache.block(forKey: "b", at: 0)
    XCTAssertNil(other, "keys do not share blocks")
  }

  func testBlocksOutliveTheInstance() async throws {
    let first = try cache()
    await first.store(block(7), forKey: "a", at: 0)
    await first.setContentLength(10, forKey: "a")
    await first.close()

    let second = try cache()
    let read = await second.block(forKey: "a", at: 0)
    XCTAssertEqual(read, block(7))
    let length = await second.contentLength(forKey: "a")
    XCTAssertEqual(length, 10)
    let used = await second.usedBytes
    XCTAssertEqual(used, 4)
  }

  /// A crash leaves at most a half-written temporary file; a block of the
  /// wrong size is damage. Both go on opening, the good block stays.
  func testHalfWrittenAndDamagedBlocksAreClearedOnOpening() async throws {
    let first = try cache()
    await first.setContentLength(10, forKey: "a")
    await first.store(block(7), forKey: "a", at: 0)
    await first.close()
    let folder = try keyDirectory()
    try Data([1, 2]).write(to: folder.appendingPathComponent("1.partial"))
    try Data([1, 2, 3]).write(to: folder.appendingPathComponent("1"))

    let second = try cache()
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    XCTAssertEqual(names, ["0", "key", "length"])
    let damaged = await second.block(forKey: "a", at: 1)
    XCTAssertNil(damaged)
    let used = await second.usedBytes
    XCTAssertEqual(used, 4)
  }

  /// A host may point the cache at a folder holding other things. They are
  /// neither counted nor ever deleted.
  func testFilesItDoesNotRecogniseAreLeftAlone() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let note = directory.appendingPathComponent("notes.txt")
    try Data("keep me".utf8).write(to: note)
    let cache = try cache()
    await cache.store(block(7), forKey: "a", at: 0)
    await cache.removeAll()
    XCTAssertTrue(FileManager.default.fileExists(atPath: note.path))
    let used = await cache.usedBytes
    XCTAssertEqual(used, 0)
  }

  /// Three blocks fit. Block 0 is the oldest but was just read; block 1 is
  /// the one nobody has touched since, and it goes. First-in-first-out
  /// would drop block 0 instead.
  func testEvictsTheLeastRecentlyUsedBlockNotTheOldest() async throws {
    let cache = try cache(capacity: 12)
    for index in 0..<3 { await cache.store(block(UInt8(index)), forKey: "a", at: Int64(index)) }
    _ = await cache.block(forKey: "a", at: 0)
    await cache.store(block(3), forKey: "a", at: 3)

    var present: [Int64] = []
    for index in Int64(0)..<4 {
      if await cache.block(forKey: "a", at: index) != nil { present.append(index) }
    }
    XCTAssertEqual(present, [0, 2, 3])
    let used = await cache.usedBytes
    XCTAssertEqual(used, 12)
  }

  /// Recency is kept on disk, so it holds across a restart.
  func testRecencySurvivesARestart() async throws {
    let first = try cache(capacity: 12)
    for index in 0..<3 { await first.store(block(UInt8(index)), forKey: "a", at: Int64(index)) }
    _ = await first.block(forKey: "a", at: 0)
    await first.close()

    let second = try cache(capacity: 12)
    await second.store(block(3), forKey: "a", at: 3)
    let evicted = await second.block(forKey: "a", at: 1)
    XCTAssertNil(evicted)
    let kept = await second.block(forKey: "a", at: 0)
    XCTAssertNotNil(kept)
  }

  /// Two instances on one folder would each keep their own count and evict
  /// each other's blocks, so the second is refused.
  func testOneInstancePerDirectory() async throws {
    let first = try cache()
    XCTAssertThrowsError(try cache()) { error in
      guard case UmbelError.cacheUnavailable = error else {
        return XCTFail("expected cacheUnavailable, got \(error)")
      }
    }
    await first.close()
    XCTAssertNoThrow(try cache())
  }

  /// Different content under the same key: what is cached no longer fits it.
  func testANewLengthDropsTheKey() async throws {
    let cache = try cache()
    await cache.setContentLength(10, forKey: "a")
    await cache.store(block(7), forKey: "a", at: 0)
    await cache.setContentLength(12, forKey: "a")
    let dropped = await cache.block(forKey: "a", at: 0)
    XCTAssertNil(dropped)
    let length = await cache.contentLength(forKey: "a")
    XCTAssertEqual(length, 12)
  }

  /// The last block holds what is left; any other size is refused.
  func testOnlyTheLastBlockMayBeShort() async throws {
    let cache = try cache()
    await cache.setContentLength(10, forKey: "a")
    await cache.store(block(9, count: 2), forKey: "a", at: 2)
    await cache.store(block(8, count: 3), forKey: "a", at: 1)
    let last = await cache.block(forKey: "a", at: 2)
    XCTAssertEqual(last, block(9, count: 2))
    let refused = await cache.block(forKey: "a", at: 1)
    XCTAssertNil(refused)
  }

  /// Without a known length, a short block cannot be told from a damaged one.
  func testAShortBlockNeedsAKnownLength() async throws {
    let cache = try cache()
    await cache.store(block(9, count: 2), forKey: "a", at: 2)
    let refused = await cache.block(forKey: "a", at: 2)
    XCTAssertNil(refused)
  }

  func testRemovingAKeyLeavesTheOthers() async throws {
    let cache = try cache()
    await cache.store(block(1), forKey: "a", at: 0)
    await cache.store(block(2), forKey: "b", at: 0)
    await cache.remove(key: "a")
    let a = await cache.block(forKey: "a", at: 0)
    let b = await cache.block(forKey: "b", at: 0)
    XCTAssertNil(a)
    XCTAssertEqual(b, block(2))
    let used = await cache.usedBytes
    XCTAssertEqual(used, 4)
  }
}
