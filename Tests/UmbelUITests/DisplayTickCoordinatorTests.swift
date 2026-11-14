import CoreMedia
import XCTest
import UmbelCore
@testable import UmbelUI

private actor ControlledRender {
  private(set) var starts = 0
  private var waiting: CheckedContinuation<PresentedFrame?, Error>?

  func render() async throws -> PresentedFrame? {
    starts += 1
    return try await withCheckedThrowingContinuation { waiting = $0 }
  }

  func finish(_ result: Result<PresentedFrame?, Error>) {
    waiting?.resume(with: result)
    waiting = nil
  }
}

private enum RenderFailure: Error { case expected }

final class DisplayTickCoordinatorTests: XCTestCase {
  private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("condition did not become true")
  }

  func testBusyTicksCoalesceWithoutMainActorCompletion() async throws {
    let controlled = ControlledRender()
    let coordinator = DisplayTickCoordinator { try await controlled.render() }
    coordinator.start()
    coordinator.tick(at: 1)
    try await waitUntil { await controlled.starts == 1 }
    coordinator.tick(at: 1.01)
    coordinator.tick(at: 1.02)
    XCTAssertEqual(coordinator.snapshot.busyTickCount, 2)
    let startsWhileBusy = await controlled.starts
    XCTAssertEqual(startsWhileBusy, 1)
    await controlled.finish(.success(nil))
    try await waitUntil { coordinator.snapshot.emptyRenderCount == 1 }
    coordinator.tick(at: 1.03)
    try await waitUntil { await controlled.starts == 2 }
    await controlled.finish(.success(nil))
    coordinator.stop()
  }

  func testStopRestartDoesNotLetOldCompletionUnlockNewWork() async throws {
    let controlled = ControlledRender()
    let coordinator = DisplayTickCoordinator { try await controlled.render() }
    coordinator.start()
    coordinator.tick(at: 1)
    try await waitUntil { await controlled.starts == 1 }
    coordinator.stop()
    coordinator.start()
    coordinator.tick(at: 2)
    XCTAssertEqual(coordinator.snapshot.busyTickCount, 1)
    await controlled.finish(.success(nil))
    try await waitUntil { !coordinator.snapshot.isRendering }
    XCTAssertEqual(coordinator.snapshot.emptyRenderCount, 0)
    coordinator.tick(at: 2.1)
    try await waitUntil { await controlled.starts == 2 }
    await controlled.finish(.success(nil))
    coordinator.stop()
  }

  func testErrorReleasesGateAndIntervalsAreMeasuredFromCallbacks() async throws {
    let controlled = ControlledRender()
    let coordinator = DisplayTickCoordinator { try await controlled.render() }
    coordinator.start()
    coordinator.tick(at: 1)
    try await waitUntil { await controlled.starts == 1 }
    coordinator.tick(at: 1.02)
    await controlled.finish(.failure(RenderFailure.expected))
    try await waitUntil { coordinator.snapshot.errorCount == 1 }
    let first = coordinator.snapshot
    XCTAssertEqual(first.tickCount, 2)
    XCTAssertEqual(try XCTUnwrap(first.lastTickInterval), 0.02, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(first.maximumTickInterval), 0.02, accuracy: 0.0001)
    XCTAssertNotNil(first.lastError)
    XCTAssertNotNil(first.lastRenderDuration)
    coordinator.tick(at: 1.04)
    try await waitUntil { await controlled.starts == 2 }
    await controlled.finish(.success(PresentedFrame(
      presentationTime: CMTime(seconds: 1, preferredTimescale: 600), droppedFrames: 3)))
    try await waitUntil { coordinator.snapshot.presentedFrameCount == 1 }
    XCTAssertEqual(coordinator.snapshot.reportedDroppedFrameCount, 3)
    coordinator.stop()
  }
}
