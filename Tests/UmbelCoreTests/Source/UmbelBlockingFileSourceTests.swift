import XCTest
@testable import UmbelCore

/// A file that is read by calls that block, as a server's is: one connection
/// at a time, which a call given up on leaves in a state nobody knows.
private final class FakeFile: UmbelBlockingFileReader, @unchecked Sendable {
  private let lock = NSLock()
  private let content: Data
  private let wake = DispatchSemaphore(value: 0)
  private var blockOnce: Set<Int64>
  private var failOnce: [Int64: UmbelError]
  private let openFailure: UmbelError?
  private var blockOpenOnce: Bool
  private var isOpen = false
  private var abandoned = false
  private var interrupted = false
  private var opens = 0
  private var closes = 0
  private var abandons = 0

  init(
    content: Data, blockOnce: Set<Int64> = [], failOnce: [Int64: UmbelError] = [:], openFailure: UmbelError? = nil,
    blockOpenOnce: Bool = false
  ) {
    self.blockOpenOnce = blockOpenOnce
    self.content = content
    self.blockOnce = blockOnce
    self.failOnce = failOnce
    self.openFailure = openFailure
  }

  var counts: (opens: Int, closes: Int, abandons: Int) {
    lock.lock(); defer { lock.unlock() }
    return (opens, closes, abandons)
  }

  func open() throws {
    lock.lock()
    opens += 1
    if interrupted { lock.unlock(); throw UmbelError.interrupted }
    if blockOpenOnce {
      blockOpenOnce = false
      lock.unlock()
      // Bounded, as a read's block is.
      let woken = wake.wait(timeout: .now() + 5)
      lock.lock()
      defer { lock.unlock() }
      if woken == .timedOut { throw UmbelError.sourceUnavailable(detail: "a blocked open was never ended") }
      throw UmbelError.interrupted
    }
    defer { lock.unlock() }
    if let openFailure { throw openFailure }
    isOpen = true
    abandoned = false
  }

  func size() -> Int64? { Int64(content.count) }

  func read(offset: Int64, maxLength: Int) throws -> Data {
    lock.lock()
    guard isOpen else { lock.unlock(); throw UmbelError.sourceUnavailable(detail: "read on a connection that is not open") }
    // A call given up on leaves the connection in a state nobody knows, until
    // it is closed and opened again: a read begun on it is a read of garbage.
    if abandoned { lock.unlock(); throw UmbelError.sourceUnavailable(detail: "read on a connection left in an unknown state") }
    if interrupted { lock.unlock(); throw UmbelError.interrupted }
    if blockOnce.remove(offset) != nil {
      lock.unlock()
      // Bounded: a call nobody ends would hold a test for good.
      let woken = wake.wait(timeout: .now() + 5)
      lock.lock()
      defer { lock.unlock() }
      if woken == .timedOut { throw UmbelError.sourceUnavailable(detail: "a blocked read was never ended") }
      if interrupted || abandoned { throw UmbelError.interrupted }
    } else {
      defer { lock.unlock() }
      if let error = failOnce.removeValue(forKey: offset) { throw error }
    }
    let start = Int(min(max(offset, 0), Int64(content.count)))
    return content.subdata(in: start..<min(start + maxLength, content.count))
  }

  func abandonCurrentCall() {
    lock.lock(); abandoned = true; abandons += 1; lock.unlock()
    wake.signal()
  }

  func requestInterrupt() {
    lock.lock(); interrupted = true; lock.unlock()
    wake.signal()
  }

  func close() {
    lock.lock(); isOpen = false; closes += 1; lock.unlock()
  }
}

final class UmbelBlockingFileSourceTests: XCTestCase {
  private let pattern = Data((0..<10_000).map { UInt8($0 % 251) })

  private func failure(of source: UmbelBlockingFileSource, offset: Int64 = 0) async -> UmbelError? {
    do {
      _ = try await source.read(offset: offset, maxLength: 16)
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  func testAnyPartOfTheFileCanBeReadInAnyOrder() async throws {
    let source = UmbelBlockingFileSource(reader: FakeFile(content: pattern))
    let start = try await source.read(offset: 0, maxLength: 100)
    XCTAssertEqual(start, pattern.prefix(100))
    let middle = try await source.read(offset: 5_000, maxLength: 100)
    XCTAssertEqual(middle, pattern.subdata(in: 5_000..<5_100))
    let back = try await source.read(offset: 10, maxLength: 20)
    XCTAssertEqual(back, pattern.subdata(in: 10..<30))
    await source.invalidate()
  }

  func testTheEndOfTheFileIsTheEnd() async throws {
    let source = UmbelBlockingFileSource(reader: FakeFile(content: pattern))
    let last = try await source.read(offset: 9_950, maxLength: 1_000)
    XCTAssertEqual(last, pattern.subdata(in: 9_950..<10_000))
    let after = try await source.read(offset: 10_000, maxLength: 10)
    XCTAssertEqual(after, Data())
    await source.invalidate()
  }

  func testTheLengthComesFromTheReader() async throws {
    let source = UmbelBlockingFileSource(reader: FakeFile(content: pattern))
    let length = await source.contentLength
    XCTAssertEqual(length, 10_000)
    await source.invalidate()
  }

  func testNothingIsOpenedUntilTheFirstUse() async throws {
    let file = FakeFile(content: pattern)
    let source = UmbelBlockingFileSource(reader: file)
    XCTAssertEqual(file.counts.opens, 0)
    _ = try await source.read(offset: 0, maxLength: 10)
    XCTAssertEqual(file.counts.opens, 1)
    _ = try await source.read(offset: 10, maxLength: 10)
    XCTAssertEqual(file.counts.opens, 1, "one connection, for as long as it serves")
    await source.invalidate()
  }

  /// What went wrong reaches the host as the reader said it, and the
  /// connection, in whatever state it is, is closed and made again for the
  /// next read: nothing is retried, and nothing is left broken.
  func testAFailureIsToldAsItIsAndTheNextReadStartsOverOnANewConnection() async throws {
    let file = FakeFile(content: pattern, failOnce: [100: .sourceUnavailable(detail: "cut")])
    let source = UmbelBlockingFileSource(reader: file)
    let error = await failure(of: source, offset: 100)
    XCTAssertEqual(error, .sourceUnavailable(detail: "cut"))
    XCTAssertEqual(file.counts.closes, 1)
    let again = try await source.read(offset: 100, maxLength: 10)
    XCTAssertEqual(again, pattern.subdata(in: 100..<110))
    XCTAssertEqual(file.counts.opens, 2)
    await source.invalidate()
  }

  func testAnErrorOpeningIsToldAsItIs() async throws {
    let source = UmbelBlockingFileSource(reader: FakeFile(content: pattern, openFailure: .unsupportedScheme("sftp")))
    let error = await failure(of: source)
    XCTAssertEqual(error, .unsupportedScheme("sftp"))
    let length = await source.contentLength
    XCTAssertNil(length)
  }

  /// Connecting is a call that blocks, and the one a host waits on longest.
  func testCancellingAReadWhileItConnectsAbandonsTheConnectionAtOnce() async throws {
    let file = FakeFile(content: pattern, blockOpenOnce: true)
    let source = UmbelBlockingFileSource(reader: file)
    let began = Date()
    let waiting = Task { try await source.read(offset: 0, maxLength: 10) }
    try await Task.sleep(nanoseconds: 200_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled read gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 2, "not at the end of the connect deadline")
    XCTAssertEqual(file.counts.abandons, 1)
    let after = try await source.read(offset: 0, maxLength: 10)
    XCTAssertEqual(after, pattern.subdata(in: 0..<10))
    await source.invalidate()
  }

  /// A read given up on is not the end of the source.
  func testCancellingAReadAbandonsItAndTheNextReadIsServed() async throws {
    let file = FakeFile(content: pattern, blockOnce: [1_000])
    let source = UmbelBlockingFileSource(reader: file)
    _ = try await source.read(offset: 0, maxLength: 10)
    let waiting = Task { try await source.read(offset: 1_000, maxLength: 10) }
    try await Task.sleep(nanoseconds: 200_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled read gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertEqual(file.counts.abandons, 1)
    let after = try await source.read(offset: 1_000, maxLength: 10)
    XCTAssertEqual(after, pattern.subdata(in: 1_000..<1_010))
    XCTAssertEqual(file.counts.opens, 2, "opened again, the old connection not trusted")
    await source.invalidate()
  }

  /// A read given up on closes the connection it was on. One already asked
  /// for behind it must wait for that, not begin on a connection being closed.
  func testAReadQueuedBehindOneThatIsGivenUpOnIsStillServed() async throws {
    let file = FakeFile(content: pattern, blockOnce: [1_000])
    let source = UmbelBlockingFileSource(reader: file)
    _ = try await source.read(offset: 0, maxLength: 10)
    let given = Task { try await source.read(offset: 1_000, maxLength: 10) }
    try await Task.sleep(nanoseconds: 200_000_000)
    let queued = Task { try await source.read(offset: 2_000, maxLength: 10) }
    try await Task.sleep(nanoseconds: 100_000_000)
    given.cancel()
    _ = try? await given.value
    let served = try await queued.value
    XCTAssertEqual(served, pattern.subdata(in: 2_000..<2_010))
    await source.invalidate()
  }

  func testInvalidatingEndsTheReadWaitingAndClosesTheReader() async throws {
    let file = FakeFile(content: pattern, blockOnce: [500])
    let source = UmbelBlockingFileSource(reader: file)
    _ = try await source.read(offset: 0, maxLength: 10)
    let waiting = Task { try await source.read(offset: 500, maxLength: 10) }
    try await Task.sleep(nanoseconds: 200_000_000)
    await source.invalidate()
    do {
      _ = try await waiting.value
      XCTFail("an invalidated source gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    let after = await failure(of: source)
    XCTAssertEqual(after, .interrupted)
    XCTAssertGreaterThanOrEqual(file.counts.closes, 1, "the connection is let go")
  }

  func testReleasingTheSourceLetsTheConnectionGo() async throws {
    let file = FakeFile(content: pattern, blockOnce: [100])
    do {
      let source = UmbelBlockingFileSource(reader: file)
      _ = try await source.read(offset: 0, maxLength: 10)
    }
    // The reader is interrupted, which is what makes it let go.
    for _ in 0..<200 where (try? file.read(offset: 0, maxLength: 1)) != nil { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertThrowsError(try file.read(offset: 0, maxLength: 1), "released: no call goes on")
  }
}
