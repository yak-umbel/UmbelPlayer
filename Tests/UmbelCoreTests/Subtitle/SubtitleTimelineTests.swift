import CoreMedia
import XCTest
@testable import UmbelCore

final class SubtitleTimelineTests: XCTestCase {
  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1000)
  }

  private func cue(_ text: String, _ start: Double, _ end: Double?) -> UmbelSubtitleCue {
    UmbelSubtitleCue(start: time(start), end: end.map(time), runs: [.init(text: text)])
  }

  private func texts(_ timeline: SubtitleTimeline, at seconds: Double) -> [String] {
    timeline.cues(at: time(seconds)).map(\.plainText)
  }

  /// Start is inside, end is not: back-to-back cues never show together.
  func testIntervalIncludesStartExcludesEnd() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("a", 1, 2))
    timeline.insert(cue("b", 2, 3))
    XCTAssertEqual(texts(timeline, at: 0.999), [])
    XCTAssertEqual(texts(timeline, at: 1), ["a"])
    XCTAssertEqual(texts(timeline, at: 2), ["b"])
    XCTAssertEqual(texts(timeline, at: 3), [])
  }

  func testOpenEndedCueLastsUntilTheNextOneStarts() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("a", 1, nil))
    XCTAssertEqual(texts(timeline, at: 100), ["a"], "nothing after it yet")
    timeline.insert(cue("b", 5, 6))
    XCTAssertEqual(texts(timeline, at: 4.9), ["a"])
    XCTAssertEqual(texts(timeline, at: 5), ["b"])
  }

  func testOverlappingCuesAllShowInStartOrder() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("late", 2, 4))
    timeline.insert(cue("early", 1, 5))
    timeline.insert(cue("same-start", 2, 3))
    XCTAssertEqual(texts(timeline, at: 2.5), ["early", "late", "same-start"])
  }

  /// A long cue far behind the query must still be found; the lookup cannot
  /// stop at the first expired neighbour.
  func testLongCueBehindManyShortOnesIsFound() {
    var timeline = SubtitleTimeline(retention: .complete)
    timeline.insert(cue("long", 0, 100))
    for index in 1..<50 {
      timeline.insert(cue("short \(index)", Double(index), Double(index) + 0.5))
    }
    XCTAssertEqual(texts(timeline, at: 30.7), ["long"])
    XCTAssertEqual(texts(timeline, at: 30.2), ["long", "short 30"])
  }

  func testWindowPrunesCuesEndedMoreThanASecondAgo() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("old", 0, 1))
    timeline.insert(cue("recent", 1, 2.5))
    timeline.insert(cue("open", 3, nil))
    timeline.prune(before: time(3.2))
    XCTAssertEqual(timeline.count, 2, "old ended 2.2 s ago; recent only 0.7 s ago")
  }

  /// External files are loaded once; seeking back must still find their cues.
  func testCompleteTimelineNeverPrunes() {
    var timeline = SubtitleTimeline(retention: .complete)
    timeline.insert(cue("old", 0, 1))
    timeline.prune(before: time(100))
    XCTAssertEqual(texts(timeline, at: 0.5), ["old"])
  }

  func testRemoveAllEmptiesIt() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("a", 0, 10))
    timeline.removeAll()
    XCTAssertEqual(texts(timeline, at: 5), [])
    XCTAssertEqual(timeline.count, 0)
  }

  /// A bitmap event replaces the whole picture: whatever shows when it
  /// starts ends there, however long its own end said it would last.
  func testCutEndsWhatIsShowingThen() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("a", 1, 30))
    timeline.insert(cue("b", 1, nil))
    timeline.cut(at: time(2))
    XCTAssertEqual(texts(timeline, at: 1.5), ["a", "b"])
    XCTAssertEqual(texts(timeline, at: 2), [], "both ended at the cut")
  }

  /// A cue that had already ended keeps its end: a cut never lengthens one.
  func testCutLeavesWhatHadAlreadyEnded() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("a", 1, nil))
    timeline.insert(cue("b", 2, 2.5))
    timeline.cut(at: time(3))
    XCTAssertEqual(texts(timeline, at: 1.5), ["a"])
    XCTAssertEqual(texts(timeline, at: 2.2), ["b"], "a ended when b started")
    XCTAssertEqual(texts(timeline, at: 2.7), [], "b ended at its own end")
  }

  func testCutLeavesWhatStartsAtOrAfterIt() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("a", 2, 4))
    timeline.cut(at: time(2))
    XCTAssertEqual(texts(timeline, at: 3), ["a"])
  }

  /// A cut gives an open-ended cue a length, and a lookup must still reach
  /// back to it past a later, shorter cue.
  func testACutCueIsStillFoundBehindALaterOne() {
    var timeline = SubtitleTimeline(retention: .window)
    timeline.insert(cue("long", 1, nil))
    timeline.cut(at: time(5))
    timeline.insert(cue("short", 2, 2.1))
    XCTAssertEqual(texts(timeline, at: 3), ["long"])
  }
}
