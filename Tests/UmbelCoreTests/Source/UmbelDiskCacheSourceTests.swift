import XCTest
@testable import UmbelCore

/// A source whose byte n is n % 251, counting how often it is read. It can
/// hand out short reads, keep its length to itself, or be unreachable.
private actor FakeSource: UmbelRandomAccessSource {
  private let length: Int64
  private let reportsLength: Bool
  private let largestRead: Int
  private var isOffline: Bool
  private(set) var reads = 0
  private(set) var isInvalidated = false

  init(length: Int64, reportsLength: Bool = true, largestRead: Int = .max, offline: Bool = false) {
    self.length = length
    self.reportsLength = reportsLength
    self.largestRead = largestRead
    self.isOffline = offline
  }

  var contentLength: Int64? { reportsLength && !isOffline ? length : nil }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    reads += 1
    if isOffline { throw UmbelError.sourceUnavailable(detail: "offline") }
    guard offset < length else { return Data() }
    let count = Int(min(Int64(min(maxLength, largestRead)), length - offset))
    return Self.bytes(from: offset, count: count)
  }

  func invalidate() async { isInvalidated = true }

  static func bytes(from offset: Int64, count: Int) -> Data {
    Data((0..<count).map { UInt8((offset + Int64($0)) % 251) })
  }
}

/// Blocks of sixteen bytes; the real size is a mebibyte.
final class UmbelDiskCacheSourceTests: XCTestCase {
  private var directory: URL!
  private var cache: UmbelDiskCache!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("UmbelDiskCacheSourceTests-\(UUID().uuidString)")
    cache = try UmbelDiskCache(directory: directory, capacity: 1_000_000, blockSize: 16)
  }

  override func tearDown() async throws {
    await cache.close()
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try? FileManager.default.removeItem(at: directory)
  }

  private func source(_ inner: FakeSource, key: String = "film") -> UmbelDiskCacheSource {
    UmbelDiskCacheSource(wrapping: inner, key: key, cache: cache)
  }

  func testASecondReadComesFromDisk() async throws {
    let inner = FakeSource(length: 40)
    let cached = source(inner)
    let first = try await cached.read(offset: 0, maxLength: 4)
    let second = try await cached.read(offset: 0, maxLength: 4)
    XCTAssertEqual(first, FakeSource.bytes(from: 0, count: 4))
    XCTAssertEqual(second, first)
    let reads = await inner.reads
    XCTAssertEqual(reads, 1, "one block fetched, then served from disk")
  }

  /// A read stops at the end of its block; the next one carries on. The
  /// protocol allows short reads, and the layers above read on.
  func testAReadStopsAtTheEndOfItsBlock() async throws {
    let cached = source(FakeSource(length: 40))
    let tail = try await cached.read(offset: 5, maxLength: 100)
    XCTAssertEqual(tail, FakeSource.bytes(from: 5, count: 11))
    let next = try await cached.read(offset: 16, maxLength: 4)
    XCTAssertEqual(next, FakeSource.bytes(from: 16, count: 4))
  }

  /// What the source has so far is handed on at once, not held until the
  /// block is whole — on a network source, the difference between the first
  /// byte now and the first byte once a mebibyte has arrived.
  func testAMissHandsOnWhatTheSourceGave() async throws {
    let inner = FakeSource(length: 40, largestRead: 5)
    let data = try await source(inner).read(offset: 0, maxLength: 16)
    XCTAssertEqual(data, FakeSource.bytes(from: 0, count: 5))
    let reads = await inner.reads
    XCTAssertEqual(reads, 1)
  }

  /// Read through in order in short pieces, a block is still kept whole.
  func testReadingABlockThroughInPiecesKeepsItWhole() async throws {
    let inner = FakeSource(length: 40, largestRead: 5)
    let cached = source(inner)
    var read = Data()
    while read.count < 16 {
      read += try await cached.read(offset: Int64(read.count), maxLength: 16 - read.count)
    }
    XCTAssertEqual(read, FakeSource.bytes(from: 0, count: 16))
    let reads = await inner.reads
    XCTAssertEqual(reads, 4)
    let held = await cache.cachedBytes(forKey: "film")
    XCTAssertEqual(held, 16, "kept whole")
  }

  /// Reads shorter than what the source gave are served from what has
  /// arrived, not asked of the source again, and the block is still kept.
  func testWhatArrivedServesTheReadsAfter() async throws {
    let inner = FakeSource(length: 40, largestRead: 10)
    let cached = source(inner)
    var read = Data()
    while read.count < 16 {
      read += try await cached.read(offset: Int64(read.count), maxLength: 4)
    }
    XCTAssertEqual(read, FakeSource.bytes(from: 0, count: 16))
    let reads = await inner.reads
    XCTAssertEqual(reads, 2, "ten bytes, then the six that finish the block")
    let held = await cache.cachedBytes(forKey: "film")
    XCTAssertEqual(held, 16)
  }

  /// A block a seek lands in the middle of is served but not kept — only a
  /// block read from its start can be — and caching goes on from the next.
  func testABlockEnteredMidwayIsServedButNotKept() async throws {
    let cached = source(FakeSource(length: 40))
    let middle = try await cached.read(offset: 8, maxLength: 8)
    XCTAssertEqual(middle, FakeSource.bytes(from: 8, count: 8))
    let before = await cache.cachedBytes(forKey: "film")
    XCTAssertEqual(before, 0)
    _ = try await cached.read(offset: 16, maxLength: 16)
    let after = await cache.cachedBytes(forKey: "film")
    XCTAssertEqual(after, 16, "the next block, read from its start, is kept")
  }

  func testTheLastBlockIsShortAndTheEndIsEmpty() async throws {
    let cached = source(FakeSource(length: 40))
    let last = try await cached.read(offset: 32, maxLength: 16)
    XCTAssertEqual(last, FakeSource.bytes(from: 32, count: 8))
    let past = try await cached.read(offset: 40, maxLength: 4)
    XCTAssertTrue(past.isEmpty)
    let held = await cache.cachedBytes(forKey: "film")
    XCTAssertEqual(held, 8, "the short last block is kept too")
  }

  /// A source that does not say how long it is: reading at its end says it.
  func testTheLengthIsLearnedAtTheEnd() async throws {
    let cached = source(FakeSource(length: 40, reportsLength: false))
    _ = try await cached.read(offset: 32, maxLength: 16)
    let end = try await cached.read(offset: 40, maxLength: 16)
    XCTAssertTrue(end.isEmpty)
    let recorded = await cache.contentLength(forKey: "film")
    XCTAssertEqual(recorded, 40)
    let offline = source(FakeSource(length: 40, offline: true))
    let length = await offline.contentLength
    XCTAssertEqual(length, 40)
    let last = try await offline.read(offset: 32, maxLength: 16)
    XCTAssertEqual(last, FakeSource.bytes(from: 32, count: 8))
  }

  /// Offline, what was cached plays; what was not fails as the source does.
  func testOfflineServesWhatIsCachedAndFailsTheRest() async throws {
    _ = try await source(FakeSource(length: 40)).read(offset: 0, maxLength: 16)

    let offlineInner = FakeSource(length: 40, offline: true)
    let offline = source(offlineInner)
    let length = await offline.contentLength
    XCTAssertEqual(length, 40, "the recorded length stands in")
    let cached = try await offline.read(offset: 0, maxLength: 16)
    XCTAssertEqual(cached, FakeSource.bytes(from: 0, count: 16))
    let end = try await offline.read(offset: 40, maxLength: 4)
    XCTAssertTrue(end.isEmpty, "the end is known without asking the source")
    do {
      _ = try await offline.read(offset: 16, maxLength: 16)
      XCTFail("not cached, and the source is unreachable")
    } catch UmbelError.sourceUnavailable {
    }
  }

  /// The same key now names something of another length: nothing held for
  /// the old content is served.
  func testChangedContentIsFetchedAfresh() async throws {
    _ = try await source(FakeSource(length: 40)).read(offset: 0, maxLength: 16)
    let newer = FakeSource(length: 48)
    let data = try await source(newer).read(offset: 0, maxLength: 16)
    XCTAssertEqual(data, FakeSource.bytes(from: 0, count: 16))
    let reads = await newer.reads
    XCTAssertEqual(reads, 1, "fetched again, not served from the old content")
  }

  /// A cache that cannot write only stops caching; playback reads on.
  func testAnUnwritableDiskFallsBackToTheSource() async throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    let inner = FakeSource(length: 40)
    let cached = source(inner)
    let first = try await cached.read(offset: 0, maxLength: 16)
    let second = try await cached.read(offset: 0, maxLength: 16)
    XCTAssertEqual(first, FakeSource.bytes(from: 0, count: 16))
    XCTAssertEqual(second, first)
    let reads = await inner.reads
    XCTAssertEqual(reads, 2, "nothing could be kept, so both went to the source")
  }

  func testInvalidationStopsReadingAndPassesOn() async throws {
    let inner = FakeSource(length: 40)
    let cached = source(inner)
    await cached.invalidate()
    let passedOn = await inner.isInvalidated
    XCTAssertTrue(passedOn)
    do {
      _ = try await cached.read(offset: 0, maxLength: 4)
      XCTFail("invalidated")
    } catch UmbelError.interrupted {
    }
  }

  /// Two sources caching one key at once both read right, and the block is
  /// held once.
  func testTwoSourcesOnOneKey() async throws {
    let one = source(FakeSource(length: 40))
    let two = source(FakeSource(length: 40))
    async let a = one.read(offset: 0, maxLength: 16)
    async let b = two.read(offset: 0, maxLength: 16)
    let (first, second) = try await (a, b)
    XCTAssertEqual(first, FakeSource.bytes(from: 0, count: 16))
    XCTAssertEqual(second, first)
    let held = await cache.cachedBytes(forKey: "film")
    XCTAssertEqual(held, 16)
  }
}
