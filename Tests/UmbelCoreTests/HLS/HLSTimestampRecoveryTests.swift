import XCTest
@testable import UmbelCore

final class HLSTimestampRecoveryTests: XCTestCase {
  private let video: Int32 = 0
  private let audio: Int32 = 1

  private func location(_ index: Int, start: Double? = nil) -> HLSSegmentStream.Location {
    .init(index: index, start: start ?? Double(index) * 2, duration: 2)
  }

  private func anchored() -> HLSTimestampRecovery {
    var recovery = HLSTimestampRecovery(tracks: [video: .video, audio: .audio])
    _ = recovery.observe(track: video, decode: 10, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 9.98, segment: location(0), positioned: true)
    _ = recovery.observe(track: video, decode: 11.96, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 11.96, segment: location(0), positioned: false)
    return recovery
  }

  func testForwardGapWaitsForBothTracksAndUsesOneCorrection() {
    var recovery = anchored()
    XCTAssertEqual(recovery.observe(track: video, decode: 20, segment: location(1), positioned: true), .waiting)
    XCTAssertEqual(recovery.observe(track: video, decode: 20.04, segment: location(1), positioned: true), .waiting)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true),
      .corrected(segment: 1, by: -8))
    XCTAssertEqual(recovery.observe(track: audio, decode: 20, segment: location(1), positioned: false), .unchanged)
  }

  func testAudioCanArriveFirstAndBackwardResetIsRecovered() {
    var recovery = anchored()
    XCTAssertEqual(recovery.observe(track: audio, decode: 0.98, segment: location(1), positioned: true), .waiting)
    XCTAssertEqual(recovery.observe(track: video, decode: 1, segment: location(1), positioned: true),
      .corrected(segment: 1, by: 11))
  }

  func testOldSegmentPacketsDoNotChangePendingBoundaryEvidence() {
    var recovery = anchored()
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    XCTAssertEqual(recovery.observe(track: audio, decode: 11.9, segment: location(0), positioned: true), .waiting)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true),
      .corrected(segment: 1, by: -8))
  }

  func testDeclaredIntervalIsPreserved() {
    var recovery = anchored()
    XCTAssertEqual(recovery.observe(track: video, decode: 20, segment: location(1, start: 10), positioned: true), .unchanged)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1, start: 10), positioned: true), .unchanged)
  }

  func testDifferentTrackJumpsAreNotCompressed() {
    for audioTime in [11.98, 17.98, 0.98] {
      var recovery = anchored()
      _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
      XCTAssertEqual(recovery.observe(track: audio, decode: audioTime, segment: location(1), positioned: true), .unchanged)
    }
  }

  func testUnlocatedOrMissingDTSDoesNotConfirmAReset() {
    var recovery = anchored()
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: false), .waiting)
    XCTAssertEqual(recovery.observe(track: audio, decode: .nan, segment: location(1), positioned: true), .waiting)
    recovery.abandon()
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true), .unchanged)
  }

  func testNonadjacentSegmentsAndFreshHistoryDoNotRecover() {
    var recovery = anchored()
    XCTAssertEqual(recovery.observe(track: video, decode: 20, segment: location(2), positioned: true), .unchanged)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(2), positioned: true), .unchanged)
    recovery = HLSTimestampRecovery(tracks: [video: .video, audio: .audio])
    XCTAssertEqual(recovery.observe(track: video, decode: 20, segment: location(10), positioned: true), .unchanged)
  }

  func testAllAudioVideoTracksMustAgree() {
    var recovery = HLSTimestampRecovery(tracks: [video: .video, audio: .audio, 2: .audio])
    for (track, time) in [(video, 10.0), (audio, 9.98), (Int32(2), 9.97)] {
      _ = recovery.observe(track: track, decode: time, segment: location(0), positioned: true)
    }
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true), .waiting)
    XCTAssertEqual(recovery.observe(track: 2, decode: 15.97, segment: location(1), positioned: true), .unchanged)
  }

  func testContinuousBoundaryAfterLateFirstTimestampsIsNotShifted() {
    var recovery = HLSTimestampRecovery(tracks: [video: .video, audio: .audio])
    _ = recovery.observe(track: video, decode: 2, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 1.98, segment: location(0), positioned: true)
    _ = recovery.observe(track: video, decode: 5.96, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 5.96, segment: location(0), positioned: true)
    let next = location(1, start: 6)
    _ = recovery.observe(track: video, decode: 6, segment: next, positioned: true)
    XCTAssertEqual(recovery.observe(track: audio, decode: 5.98, segment: next, positioned: true), .unchanged)
  }

  func testContinuousBoundaryAfterAnInternalJumpIsNotShifted() {
    var recovery = anchored()
    _ = recovery.observe(track: video, decode: 19.96, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 19.96, segment: location(0), positioned: true)
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true), .unchanged)
  }

  func testPacketDurationCompletesBoundaryEvidence() {
    var recovery = HLSTimestampRecovery(tracks: [video: .video, audio: .audio])
    _ = recovery.observe(track: video, decode: 10, duration: 2, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 9.98, duration: 2, segment: location(0), positioned: true)
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true),
      .corrected(segment: 1, by: -8))
  }

  func testLateOldAudioContinuationCompletesBoundaryEvidence() {
    var recovery = HLSTimestampRecovery(tracks: [video: .video, audio: .audio])
    _ = recovery.observe(track: video, decode: 10, segment: location(0), positioned: true)
    _ = recovery.observe(track: audio, decode: 9.98, segment: location(0), positioned: true)
    _ = recovery.observe(track: video, decode: 11.96, segment: location(0), positioned: true)
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    _ = recovery.observe(track: audio, decode: 11.96, segment: location(0), positioned: false)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true),
      .corrected(segment: 1, by: -8))
  }

  func testLateOldAudioContinuationCanDisproveTheJump() {
    var recovery = anchored()
    _ = recovery.observe(track: video, decode: 20, segment: location(1), positioned: true)
    _ = recovery.observe(track: audio, decode: 19.96, segment: location(0), positioned: false)
    XCTAssertEqual(recovery.observe(track: audio, decode: 19.98, segment: location(1), positioned: true), .unchanged)
  }
}
