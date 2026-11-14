import XCTest
@testable import UmbelCore

final class RebufferGateTests: XCTestCase {
  func testStartsHoldingUntilThereIsEnoughToStart() {
    var gate = RebufferGate()
    XCTAssertTrue(gate.isHolding)
    XCTAssertFalse(gate.update(isStarving: true, hasEnoughToStart: false, hasEnoughToResume: false))
    XCTAssertTrue(gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: false))
    XCTAssertFalse(gate.isHolding)
  }

  /// Between the two thresholds the gate keeps whatever state it is in.
  func testHysteresisBetweenTheThresholds() {
    var gate = RebufferGate()
    _ = gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: true)

    // Below the start threshold, above the low watermark: keep playing.
    XCTAssertFalse(gate.update(isStarving: false, hasEnoughToStart: false, hasEnoughToResume: false))
    XCTAssertFalse(gate.isHolding)

    XCTAssertTrue(gate.update(isStarving: true, hasEnoughToStart: false, hasEnoughToResume: false))
    XCTAssertTrue(gate.isHolding)

    // Back above the low watermark but still short: keep waiting.
    XCTAssertFalse(gate.update(isStarving: false, hasEnoughToStart: false, hasEnoughToResume: false))
    XCTAssertTrue(gate.isHolding)
  }

  /// After running dry, starting-level data is not enough to resume: a link
  /// that could not keep up once will not straight away, and resuming early
  /// makes playback stutter in short bursts.
  func testRunningDryNeedsMoreToResumeThanToStart() {
    var gate = RebufferGate()
    _ = gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: false)
    _ = gate.update(isStarving: true, hasEnoughToStart: false, hasEnoughToResume: false)

    XCTAssertFalse(gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: false))
    XCTAssertTrue(gate.isHolding, "the start threshold is not enough after a stall")
    XCTAssertTrue(gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: true))
    XCTAssertFalse(gate.isHolding)
  }

  /// A seek empties the cache on purpose; it is a new start, not a stall.
  func testHoldAfterASeekStartsAgainAtTheStartThreshold() {
    var gate = RebufferGate()
    _ = gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: false)
    _ = gate.update(isStarving: true, hasEnoughToStart: false, hasEnoughToResume: false)
    gate.hold()
    XCTAssertTrue(gate.update(isStarving: false, hasEnoughToStart: true, hasEnoughToResume: false))
  }
}
