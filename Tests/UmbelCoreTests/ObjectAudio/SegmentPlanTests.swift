import CoreMedia
import XCTest
@testable import UmbelCore

/// Where a sound track's segments fall: a whole number of frames each, laid
/// on the track's shifted time, and the playlist that lists them.
final class SegmentPlanTests: XCTestCase {
  private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

  /// 12 s of E-AC-3 (32 ms frames) starting 5 ms early, as the fixture does.
  private let plan = SegmentPlan(
    frameDuration: CMTime(value: 1536, timescale: 48_000), framesPerSegment: 188,
    duration: CMTime(seconds: 12, preferredTimescale: 1_000), shift: CMTime(value: 5, timescale: 1_000))

  func testSegmentsAreAWholeNumberOfFrames() {
    XCTAssertEqual(plan.segmentDuration.seconds, 6.016, accuracy: 1e-9)
    XCTAssertEqual(plan.count, 2)
    XCTAssertEqual(plan.length(of: 0).seconds, 6.016, accuracy: 1e-9)
    XCTAssertEqual(plan.length(of: 1).seconds, 12.005 - 6.016, accuracy: 1e-6, "the rest, shift included")
  }

  /// A packet goes by its nearest frame, so millisecond container times on
  /// either side of a boundary still land in the right segment.
  func testAPacketGoesToTheSegmentOfItsNearestFrame() {
    XCTAssertEqual(plan.index(of: time(-0.005)), 0, "the first frame, before 0")
    XCTAssertEqual(plan.index(of: time(5.979)), 0, "frame 187")
    XCTAssertEqual(plan.index(of: time(6.011)), 1, "frame 188 opens the next")
    XCTAssertEqual(plan.index(of: time(6.0105)), 1, "half a millisecond off")
    XCTAssertEqual(plan.index(of: time(99)), 1, "past the end: the last")
  }

  func testASeekStartsFromItsSegmentsFirstFrame() {
    XCTAssertEqual(plan.index(of: time(7)), 1)
    XCTAssertEqual(plan.start(of: 1).seconds, 6.011, accuracy: 1e-9, "in the film's time")
    XCTAssertEqual(plan.start(of: 0).seconds, -0.005, accuracy: 1e-9)
  }

  func testFramesAreCountedFromTheShiftedStart() {
    XCTAssertEqual(plan.frame(of: time(-0.005)), 0)
    XCTAssertEqual(plan.frame(of: time(5.979)), 187)
    XCTAssertEqual(plan.frame(of: time(-0.04)), -1, "before the track's start")
  }

  /// The system player asks for the segment holding the target and the one
  /// before; the holding one is found a frame early, so that rounding on
  /// either side of a boundary cannot leave it unread.
  func testASeekReadsFromTheSegmentBeforeTheOneHoldingTheTarget() {
    // 2.016 s segments, the track a 32 ms frame later on the player's clock.
    let frame = CMTime(value: 1536, timescale: 48_000)
    let plan = SegmentPlan(
      frameDuration: frame, framesPerSegment: 63,
      duration: CMTime(seconds: 12, preferredTimescale: 1_000), shift: frame)
    XCTAssertEqual(plan.firstSegment(forSeekTo: time(7)), 2, "7 s is in segment 3")
    XCTAssertEqual(plan.firstSegment(forSeekTo: time(6.016)), 1, "right where segment 3 starts: one more")
    XCTAssertEqual(plan.firstSegment(forSeekTo: time(6.05)), 2)
    XCTAssertEqual(plan.firstSegment(forSeekTo: time(0)), 0)
    XCTAssertEqual(plan.firstSegment(forSeekTo: time(99)), 4, "past the end: the one before the last")
  }

  func testThePlaylistCanSayWhereToStart() {
    let text = plan.playlist(initName: "init.mp4", segmentName: { "seg\($0).m4s" }, start: time(7))
    XCTAssertTrue(text.contains("#EXT-X-START:TIME-OFFSET=7.005000,PRECISE=YES\n#EXT-X-MAP"), text)
  }

  func testThePlaylistListsEverySegment() {
    XCTAssertEqual(plan.playlist(initName: "init.mp4", segmentName: { "seg\($0).m4s" }), """
      #EXTM3U
      #EXT-X-VERSION:7
      #EXT-X-TARGETDURATION:6
      #EXT-X-MEDIA-SEQUENCE:0
      #EXT-X-PLAYLIST-TYPE:VOD
      #EXT-X-INDEPENDENT-SEGMENTS
      #EXT-X-MAP:URI="init.mp4"
      #EXTINF:6.016000,
      seg0.m4s
      #EXTINF:5.989000,
      seg1.m4s
      #EXT-X-ENDLIST

      """)
  }
}
