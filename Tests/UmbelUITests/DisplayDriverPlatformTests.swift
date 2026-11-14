#if os(iOS)
import XCTest
import UIKit
import UmbelCore
@testable import UmbelUI

private actor RenderCount {
  private(set) var value = 0
  func render() -> PresentedFrame? {
    value += 1
    return nil
  }
}

/// Holds nothing; a render closure captures it so a test can watch, through
/// a weak reference, for the driver letting go of that closure.
private final class Witness: Sendable {}

@MainActor
final class DisplayDriverPlatformTests: XCTestCase {
  private func waitForTicks(_ driver: UmbelDisplayDriver) async throws {
    for _ in 0..<100 {
      if driver.statistics.tickCount > 0 { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("display link did not tick")
  }

  func testDisplayLinkKeepsTickingDuringBoundedMainThreadStall() async throws {
    let count = RenderCount()
    let driver = UmbelDisplayDriver { await count.render() }
    driver.start()
    defer { driver.stop() }
    try await waitForTicks(driver)
    let before = driver.statistics.tickCount
    let renderedBefore = driver.statistics.emptyRenderCount
    // Synchronous helper ensures the main actor cannot service callbacks.
    blockMainThread(for: 0.2)
    XCTAssertGreaterThan(driver.statistics.tickCount, before)
    XCTAssertGreaterThan(driver.statistics.emptyRenderCount, renderedBefore)
    print("Display main stall 200ms: ticks=\(driver.statistics.tickCount - before) completedCalls=\(driver.statistics.emptyRenderCount - renderedBefore)")
    let rendered = await count.value
    XCTAssertGreaterThan(rendered, 0)
  }

  func testStopAndRestartOwnTheRunLoop() async throws {
    let driver = UmbelDisplayDriver { nil }
    driver.start()
    try await waitForTicks(driver)
    driver.stop()
    let stopped = driver.statistics.tickCount
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, stopped)
    driver.start()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertGreaterThan(driver.statistics.tickCount, stopped)
    driver.stop()
  }

  func testVisibilityAndBackgroundNotificationsGateForegroundRendering() async throws {
    let driver = UmbelDisplayDriver { nil }
    driver.start()
    defer { driver.stop() }
    try await waitForTicks(driver)
    driver.setDrawableAvailable(false)
    let hidden = driver.statistics.tickCount
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, hidden)

    // Exercise lifecycle handling without moving the test host out of the
    // foreground. Actual OS background execution is a device acceptance check.
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    driver.setDrawableAvailable(true)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, hidden, "visibility alone must not restart background work")

    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    for _ in 0..<100 {
      if driver.statistics.tickCount > hidden { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThan(driver.statistics.tickCount, hidden)
  }

  /// In the background the display link does not fire, and nothing is
  /// drawn — except for picture in picture, whose small window shows what is
  /// drawn: then a timer drives it, until the window closes.
  func testPictureInPictureKeepsDrawingInTheBackground() async throws {
    let driver = UmbelDisplayDriver { nil }
    driver.start()
    defer { driver.stop() }
    try await waitForTicks(driver)
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    try await Task.sleep(nanoseconds: 50_000_000)
    let background = driver.statistics.tickCount
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, background, "nothing drawn in the background")

    driver.setPictureInPictureActive(true)
    try await Task.sleep(nanoseconds: 200_000_000)
    let drawn = driver.statistics.tickCount - background
    XCTAssertGreaterThan(drawn, 5, "about sixty a second")

    driver.setPictureInPictureActive(false)
    try await Task.sleep(nanoseconds: 50_000_000)
    let closed = driver.statistics.tickCount
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, closed, "the window closed")

    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    for _ in 0..<100 where driver.statistics.tickCount == closed {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThan(driver.statistics.tickCount, closed)
  }

  /// Open in the foreground with its view gone — the host showing another
  /// screen — picture in picture is still drawn.
  func testPictureInPictureIsDrawnWithoutADrawable() async throws {
    let driver = UmbelDisplayDriver { nil }
    driver.setDrawableAvailable(false)
    driver.start()
    defer { driver.stop() }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, 0)
    driver.setPictureInPictureActive(true)
    try await waitForTicks(driver)
  }

  func testStartingWhileHiddenCanResumeWhenAttached() async throws {
    let driver = UmbelDisplayDriver { nil }
    driver.setDrawableAvailable(false)
    driver.start()
    defer { driver.stop() }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(driver.statistics.tickCount, 0)
    driver.setDrawableAvailable(true)
    try await waitForTicks(driver)
    XCTAssertGreaterThan(driver.statistics.tickCount, 0)
  }

  // The display thread holds the render closure until it exits, so a
  // witness captured by that closure outliving its driver means a thread
  // that never finished, and everything the closure renders kept with it.

  func testAStoppedDriverLetsGoOfWhatItRenders() async throws {
    weak var witness: Witness?
    do {
      let held = Witness()
      witness = held
      let driver = UmbelDisplayDriver { _ = held; return nil }
      driver.start()
      try await waitForTicks(driver)
      driver.stop()
    }
    try await expectReleased { witness }
  }

  func testReleasingARunningDriverLetsGoOfWhatItRenders() async throws {
    weak var witness: Witness?
    do {
      let held = Witness()
      witness = held
      let driver = UmbelDisplayDriver { _ = held; return nil }
      driver.start()
      try await waitForTicks(driver)
    }
    try await expectReleased { witness }
  }

  /// Stopping right after starting races the thread, which sees the stop
  /// and finishes at once; the stop request must not then be queued for a
  /// thread that is already gone.
  func testStoppingRightAfterStartingLetsGoOfWhatItRenders() async throws {
    weak var witness: Witness?
    do {
      let held = Witness()
      witness = held
      for _ in 0..<20 {
        let driver = UmbelDisplayDriver { _ = held; return nil }
        driver.start()
        driver.stop()
      }
    }
    try await expectReleased { witness }
  }

  func testStoppingWhileDrawingInTheBackgroundLetsGoOfWhatItRenders() async throws {
    weak var witness: Witness?
    do {
      let held = Witness()
      witness = held
      let driver = UmbelDisplayDriver { _ = held; return nil }
      driver.start()
      try await waitForTicks(driver)
      NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      driver.setPictureInPictureActive(true)
      let background = driver.statistics.tickCount
      for _ in 0..<100 where driver.statistics.tickCount == background {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      XCTAssertGreaterThan(driver.statistics.tickCount, background, "the timer did not tick")
      driver.stop()
    }
    NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
    try await expectReleased { witness }
  }

  func testRestartingRepeatedlyLetsGoOfWhatItRenders() async throws {
    weak var witness: Witness?
    do {
      let held = Witness()
      witness = held
      let driver = UmbelDisplayDriver { _ = held; return nil }
      for _ in 0..<5 {
        let before = driver.statistics.tickCount
        driver.start()
        for _ in 0..<100 where driver.statistics.tickCount == before {
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(driver.statistics.tickCount, before, "the display link did not tick")
        driver.stop()
      }
    }
    try await expectReleased { witness }
  }

  private func expectReleased(_ witness: () -> Witness?,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<100 where witness() != nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNil(witness(), "the display thread still holds the render closure", file: file, line: line)
  }

  private func blockMainThread(for duration: TimeInterval) {
    Thread.sleep(forTimeInterval: duration)
  }
}
#endif
