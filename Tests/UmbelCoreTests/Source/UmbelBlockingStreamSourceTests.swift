import XCTest
@testable import UmbelCore

/// A reader that does what a script says, and records what was done to it.
private final class ScriptedReader: UmbelBlockingByteReader, @unchecked Sendable {
  enum Step {
    case data(Data)
    case end
    case fail(UmbelError)
    /// Blocks until `release()`, as a read waiting for the network does, and
    /// until interrupted, when it throws.
    case block
  }

  private let lock = NSLock()
  private var steps: [Step]
  private let wake = DispatchSemaphore(value: 0)
  private var interrupted = false
  private var opens = 0
  private var closes = 0
  private let openFailure: UmbelError?

  init(_ steps: [Step], openFailure: UmbelError? = nil) {
    self.steps = steps
    self.openFailure = openFailure
  }

  var openCount: Int { lock.lock(); defer { lock.unlock() }; return opens }
  var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }

  func release() { wake.signal() }

  func open() throws {
    lock.lock(); opens += 1; lock.unlock()
    if let openFailure { throw openFailure }
  }

  func read(maxLength: Int) throws -> Data {
    while true {
      lock.lock()
      if interrupted { lock.unlock(); throw UmbelError.interrupted }
      guard !steps.isEmpty else { lock.unlock(); return Data() }
      let step = steps.first!
      if case .block = step {
        lock.unlock()
        wake.wait()
        lock.lock()
        if interrupted { lock.unlock(); throw UmbelError.interrupted }
        steps.removeFirst()
        lock.unlock()
        continue
      }
      steps.removeFirst()
      lock.unlock()
      switch step {
      case .data(let data): return data
      case .end: return Data()
      case .fail(let error): throw error
      case .block: continue
      }
    }
  }

  func requestInterrupt() {
    lock.lock(); interrupted = true; lock.unlock()
    wake.signal()
  }

  func close() { lock.lock(); closes += 1; lock.unlock() }
}

final class UmbelBlockingStreamSourceTests: XCTestCase {
  private func readAll(_ source: UmbelBlockingStreamSource) async throws -> Data {
    var all = Data()
    while true {
      let next = try await source.readNext(maxLength: 1 << 16)
      if next.isEmpty { return all }
      all += next
    }
  }

  private func failure(of source: UmbelBlockingStreamSource) async -> UmbelError? {
    do {
      _ = try await source.readNext(maxLength: 16)
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  func testBytesComeInOrderAndTheEndIsTheEnd() async throws {
    let reader = ScriptedReader([.data(Data([1, 2, 3])), .data(Data([4])), .end])
    let source = UmbelBlockingStreamSource(reader: reader)
    let all = try await readAll(source)
    XCTAssertEqual(all, Data([1, 2, 3, 4]))
    let again = try await source.readNext(maxLength: 16)
    XCTAssertEqual(again, Data(), "the end stays the end")
    let length = await source.contentLength
    XCTAssertNil(length)
  }

  func testNothingIsOpenedUntilTheFirstRead() async throws {
    let reader = ScriptedReader([.end])
    let source = UmbelBlockingStreamSource(reader: reader)
    XCTAssertEqual(reader.openCount, 0)
    _ = try await source.readNext(maxLength: 16)
    XCTAssertEqual(reader.openCount, 1)
    await source.invalidate()
  }

  /// The reader's own words are the host's, not words about words.
  func testAnErrorOfTheReadersIsToldAsItIs() async throws {
    let reader = ScriptedReader([.data(Data([1])), .fail(.sourceUnavailable(detail: "cut"))])
    let source = UmbelBlockingStreamSource(reader: reader)
    let first = try await source.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1]))
    let error = await failure(of: source)
    XCTAssertEqual(error, .sourceUnavailable(detail: "cut"))
    let again = await failure(of: source)
    XCTAssertEqual(again, .sourceUnavailable(detail: "cut"), "a stream that has failed has failed")
  }

  func testAnErrorOpeningIsToldAsItIs() async throws {
    let reader = ScriptedReader([], openFailure: .unsupportedScheme("srt"))
    let source = UmbelBlockingStreamSource(reader: reader)
    let error = await failure(of: source)
    XCTAssertEqual(error, .unsupportedScheme("srt"))
    XCTAssertEqual(reader.closeCount, 1, "what failed to open is closed all the same")
  }

  /// A read given up on is not the stream ending.
  func testCancellingAReadDoesNotEndTheStream() async throws {
    let reader = ScriptedReader([.data(Data([1])), .block, .data(Data([2, 3])), .end])
    let source = UmbelBlockingStreamSource(reader: reader)
    let first = try await source.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1]))
    let waiting = Task { try await source.readNext(maxLength: 16) }
    try await Task.sleep(nanoseconds: 150_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled read gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    reader.release()
    let next = try await source.readNext(maxLength: 16)
    XCTAssertEqual(next, Data([2, 3]))
    await source.invalidate()
  }

  func testInvalidatingEndsTheReadWaitingAndClosesTheReader() async throws {
    let reader = ScriptedReader([.block])
    let source = UmbelBlockingStreamSource(reader: reader)
    let waiting = Task { try await source.readNext(maxLength: 16) }
    try await Task.sleep(nanoseconds: 150_000_000)
    await source.invalidate()
    do {
      _ = try await waiting.value
      XCTFail("an invalidated source gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    let after = await failure(of: source)
    XCTAssertEqual(after, .interrupted)
    for _ in 0..<200 where reader.closeCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(reader.closeCount, 1, "the connection is let go, once")
  }

  func testReleasingTheSourceClosesTheReader() async throws {
    let reader = ScriptedReader([.data(Data([1])), .block])
    do {
      let source = UmbelBlockingStreamSource(reader: reader)
      let first = try await source.readNext(maxLength: 16)
      XCTAssertEqual(first, Data([1]))
    }
    for _ in 0..<200 where reader.closeCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(reader.closeCount, 1)
  }
}
