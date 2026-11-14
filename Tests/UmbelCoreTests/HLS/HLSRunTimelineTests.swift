import CoreMedia
import XCTest
@testable import UmbelCore

/// Each run's own timestamps moved onto the playlist's timeline, one offset
/// a run, so sound and picture keep their places within it. The numbers are
/// those measured on a real site's playlist with ads spliced in.
final class HLSRunTimelineTests: XCTestCase {
  private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 90_000) }

  private func place(_ timeline: inout HLSRunTimeline, _ own: Double, lasting: Double = 0.04) -> Double {
    timeline.place(presentation: t(own), decode: t(own), duration: t(lasting)).presentation.seconds
  }

  /// A spliced ad: its timestamps start over, the film's run on past it.
  func testAnAdAndTheFilmAfterItLandWhereThePlaylistPutsThem() {
    var timeline = HLSRunTimeline()
    timeline.beginRun(startingAt: 0, continuing: false)
    XCTAssertEqual(place(&timeline, 1.48), 0, accuracy: 0.001)
    XCTAssertEqual(place(&timeline, 297.95), 296.47, accuracy: 0.001)

    timeline.beginRun(startingAt: 296.5, continuing: true)
    XCTAssertEqual(place(&timeline, 1.41), 296.5, accuracy: 0.001)
    XCTAssertEqual(place(&timeline, 20.5), 315.59, accuracy: 0.001)

    timeline.beginRun(startingAt: 315.57, continuing: true)
    XCTAssertEqual(place(&timeline, 297.91), 315.57, accuracy: 0.001)
    XCTAssertEqual(place(&timeline, 297.99), 315.65, accuracy: 0.001)
  }

  /// A tag with nothing behind it: the timestamps run on, and so does the
  /// offset. The playlist's rounded durations put the run 30 ms later than
  /// its timestamps do; anchored afresh, the picture would jump by that.
  func testATagWhoseTimestampsRunOnKeepsTheOffset() {
    var timeline = HLSRunTimeline()
    timeline.beginRun(startingAt: 0, continuing: false)
    _ = place(&timeline, 1.48)
    _ = place(&timeline, 13.44)
    timeline.beginRun(startingAt: 12.03, continuing: true)
    XCTAssertEqual(place(&timeline, 13.48), 12.0, accuracy: 0.001)
  }

  /// After a seek there is no run before to follow.
  func testASeekAnchorsAfresh() {
    var timeline = HLSRunTimeline()
    timeline.beginRun(startingAt: 0, continuing: false)
    _ = place(&timeline, 1.48)
    timeline.beginRun(startingAt: 1_531.29, continuing: false)
    XCTAssertEqual(place(&timeline, 1_497.94), 1_531.29, accuracy: 0.001)
  }

  func testMissingTimesStayMissing() {
    var timeline = HLSRunTimeline()
    timeline.beginRun(startingAt: 10, continuing: false)
    let placed = timeline.place(presentation: .invalid, decode: t(5), duration: .invalid)
    XCTAssertFalse(placed.presentation.isValid)
    XCTAssertEqual(placed.decode.seconds, 10, accuracy: 0.001)
  }

  func testSharedCorrectionsPreserveReorderAndDelayedOldPackets() {
    var timeline = HLSRunTimeline()
    timeline.beginRun(startingAt: 0, continuing: false)
    _ = timeline.place(presentation: t(10), decode: t(9.92), duration: t(0.04), segment: 0)
    timeline.correct(by: -8, startingAt: 1)
    let next = timeline.place(presentation: t(20), decode: t(19.92), duration: t(0.04), segment: 1)
    XCTAssertEqual(next.presentation.seconds, 2, accuracy: 0.001)
    XCTAssertEqual(next.decode.seconds, 1.92, accuracy: 0.001)
    let audio = timeline.place(presentation: t(19.98), decode: t(19.98), duration: t(0.02), segment: 1)
    XCTAssertEqual(audio.presentation.seconds, 1.98, accuracy: 0.001)
    let late = timeline.place(presentation: t(11.96), decode: t(11.88), duration: t(0.04), segment: 0)
    XCTAssertEqual(late.presentation.seconds, 1.96, accuracy: 0.001)
    timeline.correct(by: -16, startingAt: 2)
    let later = timeline.place(presentation: t(38), decode: t(37.92), duration: t(0.04), segment: 2)
    XCTAssertEqual(later.presentation.seconds, 4, accuracy: 0.001)
    timeline.beginRun(startingAt: 30, continuing: false)
    XCTAssertEqual(place(&timeline, 38), 30, accuracy: 0.001)
  }
}
