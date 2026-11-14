import XCTest
@testable import UmbelFFmpegSupport

private struct ProbeError: Error, Equatable {
  let marker: Int
}

private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int] = []

  func append(_ value: Int) {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
  }

  func count() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }
}

final class SerialWorkerThreadTests: XCTestCase {
  func testRunReturnsValue() async throws {
    let thread = SerialWorkerThread(name: "test-return")
    defer { thread.shutdown() }
    let value = try await thread.run { 6 * 7 }
    XCTAssertEqual(value, 42)
  }

  func testRunPropagatesThrownError() async {
    let thread = SerialWorkerThread(name: "test-throw")
    defer { thread.shutdown() }
    do {
      _ = try await thread.run { () throws -> Int in throw ProbeError(marker: 9) }
      XCTFail("the error is passed out")
    } catch let error as ProbeError {
      XCTAssertEqual(error, ProbeError(marker: 9))
    } catch {
      XCTFail("expected ProbeError, got \(error)")
    }
  }

  func testAllWorkRunsOnTheSameNonCooperativeThread() async throws {
    let thread = SerialWorkerThread(name: "test-affinity")
    defer { thread.shutdown() }
    let first = try await thread.run { Thread.current.name }
    let second = try await thread.run { Thread.current.name }
    XCTAssertEqual(first, "test-affinity")
    XCTAssertEqual(second, first, "all work lands on the same thread")
  }

  func testWorkIsSerialised() async throws {
    let thread = SerialWorkerThread(name: "test-serial")
    defer { thread.shutdown() }
    let recorder = Recorder()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask {
          _ = try? await thread.run { recorder.append(index) }
        }
      }
    }
    XCTAssertEqual(recorder.count(), 20)
  }

  func testShutdownIsIdempotent() {
    let thread = SerialWorkerThread(name: "test-shutdown")
    thread.shutdown()
    thread.shutdown()
  }

  func testRunAfterShutdownThrows() async {
    let thread = SerialWorkerThread(name: "test-after-shutdown")
    thread.shutdown()
    do {
      _ = try await thread.run { 1 }
      XCTFail("handing out work after shutdown throws")
    } catch {
      // Any error will do; what matters is not hanging silently
    }
  }
}
