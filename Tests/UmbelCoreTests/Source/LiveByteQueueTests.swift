import XCTest
@testable import UmbelCore

private final class Tally: @unchecked Sendable {
  private let lock = NSLock()
  private var holds = 0
  private var releases = 0

  var counts: (holds: Int, releases: Int) {
    lock.lock(); defer { lock.unlock() }
    return (holds, releases)
  }

  func held() { lock.lock(); holds += 1; lock.unlock() }
  func released() { lock.lock(); releases += 1; lock.unlock() }
}

final class LiveByteQueueTests: XCTestCase {
  func testReadsComeInTheOrderTheBytesArrived() async {
    let queue = LiveByteQueue()
    queue.append(Data([1, 2, 3]))
    queue.append(Data([4, 5]))
    let first = await queue.take(maxLength: 16)
    let second = await queue.take(maxLength: 16)
    XCTAssertEqual(first, .data(Data([1, 2, 3])))
    XCTAssertEqual(second, .data(Data([4, 5])))
  }

  func testAReadNeverReturnsMoreThanAskedAndKeepsTheRest() async {
    let queue = LiveByteQueue()
    queue.append(Data([1, 2, 3, 4, 5]))
    let first = await queue.take(maxLength: 2)
    let second = await queue.take(maxLength: 2)
    let third = await queue.take(maxLength: 2)
    XCTAssertEqual(first, .data(Data([1, 2])))
    XCTAssertEqual(second, .data(Data([3, 4])))
    XCTAssertEqual(third, .data(Data([5])))
  }

  func testAReadWaitsForBytesThatHaveNotCome() async throws {
    let queue = LiveByteQueue()
    let reading = Task { await queue.take(maxLength: 8) }
    try await Task.sleep(nanoseconds: 50_000_000)
    queue.append(Data([9]))
    let taken = await reading.value
    XCTAssertEqual(taken, .data(Data([9])))
  }

  func testTheEndComesAfterEverythingBufferedBeforeIt() async {
    let queue = LiveByteQueue()
    queue.append(Data([1, 2]))
    queue.finish(.end)
    let first = await queue.take(maxLength: 8)
    let second = await queue.take(maxLength: 8)
    let third = await queue.take(maxLength: 8)
    XCTAssertEqual(first, .data(Data([1, 2])))
    XCTAssertEqual(second, .end)
    XCTAssertEqual(third, .end, "the end stays the end")
  }

  func testAFailureComesAfterEverythingBufferedBeforeIt() async {
    let queue = LiveByteQueue()
    queue.append(Data([1]))
    queue.finish(.failure(.sourceUnavailable(detail: "cut")))
    let first = await queue.take(maxLength: 8)
    let second = await queue.take(maxLength: 8)
    XCTAssertEqual(first, .data(Data([1])))
    XCTAssertEqual(second, .failure(.sourceUnavailable(detail: "cut")))
  }

  /// A stream is over once, in one way: a cut that follows the end is not
  /// the stream failing.
  func testTheFirstOutcomeIsTheOnlyOne() async {
    let queue = LiveByteQueue()
    queue.finish(.end)
    queue.finish(.failure(.sourceUnavailable(detail: "late")))
    let taken = await queue.take(maxLength: 8)
    XCTAssertEqual(taken, .end)
  }

  func testCancellingAReadWakesItWithoutClosing() async throws {
    let queue = LiveByteQueue()
    let reading = Task { await queue.take(maxLength: 8) }
    try await Task.sleep(nanoseconds: 50_000_000)
    reading.cancel()
    let woken = await reading.value
    XCTAssertEqual(woken, .woken)
    queue.append(Data([7]))
    let next = await queue.take(maxLength: 8)
    XCTAssertEqual(next, .data(Data([7])))
  }

  /// Cancelled before the read begins: nothing is left to wake it.
  func testAReadAlreadyCancelledDoesNotWaitForever() async {
    let queue = LiveByteQueue()
    let reading = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await queue.take(maxLength: 8)
    }
    let taken = await reading.value
    XCTAssertEqual(taken, .woken)
  }

  func testAReadCancelledWhileBytesAreThereStillGetsThem() async {
    let queue = LiveByteQueue()
    queue.append(Data([1, 2]))
    let reading = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await queue.take(maxLength: 8)
    }
    let taken = await reading.value
    XCTAssertEqual(taken, .data(Data([1, 2])), "bytes taken are never dropped")
  }

  func testClosingDropsWhatIsBufferedAndInterruptsEveryRead() async throws {
    let queue = LiveByteQueue()
    queue.append(Data([1, 2, 3]))
    queue.close()
    let afterClose = await queue.take(maxLength: 8)
    XCTAssertEqual(afterClose, .failure(.interrupted))
    XCTAssertEqual(queue.bufferedCount, 0)

    let waiting = LiveByteQueue()
    let reading = Task { await waiting.take(maxLength: 8) }
    try await Task.sleep(nanoseconds: 50_000_000)
    waiting.close()
    let taken = await reading.value
    XCTAssertEqual(taken, .failure(.interrupted))
  }

  func testHoldAboveTheHighWatermarkAndReleaseBelowTheLowOne() async {
    let tally = Tally()
    let queue = LiveByteQueue(
      highWatermark: 10, lowWatermark: 4, hold: { tally.held() }, release: { tally.released() })
    queue.append(Data(repeating: 0, count: 8))
    XCTAssertEqual(tally.counts.holds, 0, "under the high watermark")
    queue.append(Data(repeating: 0, count: 8))
    queue.append(Data(repeating: 0, count: 8))
    XCTAssertEqual(tally.counts.holds, 1, "held once, however much more comes")

    _ = await queue.take(maxLength: 8)
    XCTAssertEqual(tally.counts.releases, 0, "still 16 buffered")
    _ = await queue.take(maxLength: 8)
    XCTAssertEqual(tally.counts.releases, 0, "8 is not below 4")
    _ = await queue.take(maxLength: 6)
    XCTAssertEqual(tally.counts.releases, 1, "2 is below 4")
    _ = await queue.take(maxLength: 8)
    XCTAssertEqual(tally.counts.releases, 1, "released once")
  }

  func testClosingReleasesWhatWasHeld() {
    let tally = Tally()
    let queue = LiveByteQueue(
      highWatermark: 4, lowWatermark: 2, hold: { tally.held() }, release: { tally.released() })
    queue.append(Data(repeating: 0, count: 8))
    queue.close()
    XCTAssertEqual(tally.counts.holds, 1)
    XCTAssertEqual(tally.counts.releases, 1, "a transfer left held would never be cancelled cleanly")
  }

  /// For a thread that fills the queue itself rather than being called into.
  func testAWriterThreadWaitsForRoomUntilReadsMakeSome() async throws {
    let queue = LiveByteQueue(highWatermark: 8, lowWatermark: 2)
    let passed = Flag()
    let writer = Thread {
      queue.append(Data(repeating: 1, count: 16))
      queue.waitForRoom()
      passed.set()
    }
    writer.start()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(passed.isSet, "full: the writer waits")
    _ = await queue.take(maxLength: 16)
    let released = await passed.waitUntilSet()
    XCTAssertTrue(released, "reads made room, and the writer went on")
  }

  func testAWriterThreadIsLetGoWhenTheQueueCloses() async throws {
    let queue = LiveByteQueue(highWatermark: 8, lowWatermark: 2)
    let passed = Flag()
    let writer = Thread {
      queue.append(Data(repeating: 1, count: 16))
      queue.waitForRoom()
      passed.set()
    }
    writer.start()
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(passed.isSet)
    queue.close()
    let released = await passed.waitUntilSet()
    XCTAssertTrue(released, "closing lets a waiting writer go")
  }
}

/// Set from a thread, read from a test.
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock(); defer { lock.unlock() }
    return value
  }

  func set() {
    lock.lock(); value = true; lock.unlock()
  }

  /// True once set, false if it is not within two seconds.
  func waitUntilSet() async -> Bool {
    for _ in 0..<200 {
      if isSet { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return isSet
  }
}
