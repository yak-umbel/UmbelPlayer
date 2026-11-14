import XCTest
@testable import UmbelFFmpegSupport

private struct BridgeProbeError: Error, Equatable {}

/// A body that waits for a long time unless cancelled.
private let longWait: @Sendable () async throws -> String = {
  try await Task.sleep(nanoseconds: 30_000_000_000)
  return "waited"
}

final class BlockingBridgeTests: XCTestCase {
  /// The bridge is for threads outside the cooperative pool, so the tests
  /// go through SerialWorkerThread too.
  private func onDedicatedThread<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let thread = SerialWorkerThread(name: "bridge-test")
    defer { thread.shutdown() }
    return try await thread.run(body)
  }

  func testReturnsValueFromAsyncBody() async throws {
    let value = try await onDedicatedThread {
      try blockingCall { 21 * 2 }
    }
    XCTAssertEqual(value, 42)
  }

  func testPropagatesErrorFromAsyncBody() async throws {
    do {
      _ = try await onDedicatedThread {
        try blockingCall { () async throws -> Int in throw BridgeProbeError() }
      }
      XCTFail("the error is passed out")
    } catch is BridgeProbeError {
      // As expected
    }
  }

  func testWaitsForSlowBody() async throws {
    let value = try await onDedicatedThread {
      try blockingCall { () async throws -> String in
        try await Task.sleep(nanoseconds: 50_000_000)
        return "done"
      }
    }
    XCTAssertEqual(value, "done", "it waits until the asynchronous work is really done")
  }

  func testManySequentialCallsDoNotDeadlock() async throws {
    let total = try await onDedicatedThread {
      var sum = 0
      for index in 0..<200 {
        sum += try blockingCall { index }
      }
      return sum
    }
    XCTAssertEqual(total, (0..<200).reduce(0, +))
  }

  func testAbandoningEndsACallWaitingOnASlowBody() async throws {
    let abandonment = ReadAbandonment()
    let started = Date()
    let thread = SerialWorkerThread(name: "bridge-test")
    defer { thread.shutdown() }
    let reading = Task {
      try await thread.run { try blockingCall(abandonment: abandonment, longWait) }
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    abandonment.abandon()
    do {
      _ = try await reading.value
      XCTFail("the call is cut short")
    } catch is CancellationError {
      // As expected: the body was cancelled
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }

  func testACallThatBeginsWhileAbandoningEndsAtOnceAndReadsGoOnAfterResume() async throws {
    let abandonment = ReadAbandonment()
    abandonment.abandon()
    let started = Date()
    do {
      _ = try await onDedicatedThread { try blockingCall(abandonment: abandonment, longWait) }
      XCTFail("a call beginning now is cut short")
    } catch is CancellationError {
      // As expected
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)

    abandonment.resume()
    let value = try await onDedicatedThread {
      try blockingCall(abandonment: abandonment) { () async throws -> Int in 7 }
    }
    XCTAssertEqual(value, 7, "reading is as it was after resume")
  }
}
