import XCTest
@testable import UmbelASSSupport

/// What stays the same, and until when, decides how often a caller needs a
/// new picture: libass redraws on every call, so the caller has to know when
/// asking again can show something else.
final class PictureSpanTests: XCTestCase {
  private let styles = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
    Style: Default,Helvetica,20,&H00FFFFFF,&H00000000,0,0,1,1,0,2,0,0,0

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

  /// Events as (start, end in seconds, text), in a script read whole.
  private func track(
    _ events: [(Double, Double, String)], effect: String = ""
  ) throws -> ASSTrack {
    func stamp(_ seconds: Double) -> String {
      let centis = Int((seconds * 100).rounded())
      return String(format: "0:%02d:%02d.%02d", centis / 6000, centis / 100 % 60, centis % 100)
    }
    let lines = events.map { start, end, text in
      "Dialogue: 0,\(stamp(start)),\(stamp(end)),Default,,0,0,0,\(effect),\(text)"
    }
    return try XCTUnwrap(ASSTrack(
      library: ASSLibrary(), scriptData: Data((styles + lines.joined(separator: "\n")).utf8)))
  }

  // MARK: The stretch

  func testALineHoldsFromItsStartToItsEnd() throws {
    let track = try track([(1, 3, "line")])
    let expected = ASSPictureSpan(start: 1_000, end: 3_000, isAnimated: false)
    XCTAssertEqual(track.pictureSpan(at: 1_000), expected)
    XCTAssertEqual(track.pictureSpan(at: 2_000), expected)
    XCTAssertEqual(track.pictureSpan(at: 2_999), expected)
  }

  func testBeforeTheFirstLineAndAfterTheLastTheStretchIsOpen() throws {
    let track = try track([(1, 3, "line")])
    XCTAssertEqual(track.pictureSpan(at: 500), ASSPictureSpan(start: nil, end: 1_000, isAnimated: false))
    XCTAssertEqual(track.pictureSpan(at: 3_000), ASSPictureSpan(start: 3_000, end: nil, isAnimated: false))
    XCTAssertEqual(try self.track([]).pictureSpan(at: 500), ASSPictureSpan(start: nil, end: nil, isAnimated: false))
  }

  func testLinesThatFollowEachOtherMakeAStretchEach() throws {
    let track = try track([(1, 2, "one"), (2, 3, "two"), (4, 5, "three")])
    XCTAssertEqual(track.pictureSpan(at: 1_500), ASSPictureSpan(start: 1_000, end: 2_000, isAnimated: false))
    XCTAssertEqual(track.pictureSpan(at: 2_000), ASSPictureSpan(start: 2_000, end: 3_000, isAnimated: false))
    XCTAssertEqual(track.pictureSpan(at: 3_500), ASSPictureSpan(start: 3_000, end: 4_000, isAnimated: false), "the gap")
  }

  func testOverlappingLinesAreCutAtTheNearestChange() throws {
    let track = try track([(1, 5, "long"), (2, 3, "inside")])
    XCTAssertEqual(track.pictureSpan(at: 1_500), ASSPictureSpan(start: 1_000, end: 2_000, isAnimated: false))
    XCTAssertEqual(track.pictureSpan(at: 2_500), ASSPictureSpan(start: 2_000, end: 3_000, isAnimated: false))
    XCTAssertEqual(track.pictureSpan(at: 3_500), ASSPictureSpan(start: 3_000, end: 5_000, isAnimated: false))
  }

  /// A line that is never on screen is no reason to draw again.
  func testALineWithNoDurationMakesNoBoundary() throws {
    let track = try track([(1, 5, "long"), (3, 3, "never shown")])
    XCTAssertEqual(track.pictureSpan(at: 2_000), ASSPictureSpan(start: 1_000, end: 5_000, isAnimated: false))
  }

  func testLinesReadLaterAreSeen() {
    let library = ASSLibrary()
    let track = ASSTrack(library: library)
    track.processCodecPrivate(Data(styles.utf8))
    XCTAssertEqual(track.pictureSpan(at: 500), ASSPictureSpan(start: nil, end: nil, isAnimated: false))
    track.processChunk(
      Data("0,0,Default,,0,0,0,,chunk".utf8), startMilliseconds: 1_000, durationMilliseconds: 1_000)
    XCTAssertEqual(track.pictureSpan(at: 500), ASSPictureSpan(start: nil, end: 1_000, isAnimated: false))
    XCTAssertEqual(track.pictureSpan(at: 1_500), ASSPictureSpan(start: 1_000, end: 2_000, isAnimated: false))
  }

  func testTheStretchContainsItsStartButNotItsEnd() {
    let span = ASSPictureSpan(start: 1_000, end: 2_000, isAnimated: false)
    XCTAssertFalse(span.contains(999))
    XCTAssertTrue(span.contains(1_000))
    XCTAssertTrue(span.contains(1_999))
    XCTAssertFalse(span.contains(2_000))
    XCTAssertTrue(ASSPictureSpan(start: nil, end: 2_000, isAnimated: false).contains(-5_000))
    XCTAssertTrue(ASSPictureSpan(start: 1_000, end: nil, isAnimated: false).contains(900_000))
  }

  func testWhichLinesJoinTheStretch() {
    let span = ASSPictureSpan(start: 1_000, end: 2_000, isAnimated: false)
    XCTAssertTrue(span.overlaps(eventStart: 500, duration: 1_000), "starts before, still on at 1.5")
    XCTAssertTrue(span.overlaps(eventStart: 1_500, duration: 100), "inside")
    XCTAssertTrue(span.overlaps(eventStart: 1_999, duration: 5_000), "starts in the last millisecond")
    XCTAssertFalse(span.overlaps(eventStart: 2_000, duration: 1_000), "starts as it ends")
    XCTAssertFalse(span.overlaps(eventStart: 0, duration: 1_000), "ends as it starts")
    XCTAssertFalse(span.overlaps(eventStart: 1_500, duration: 0), "never shown")
    XCTAssertTrue(ASSPictureSpan(start: nil, end: nil, isAnimated: false).overlaps(eventStart: 9_000, duration: 1))
  }

  // MARK: What moves by itself

  private func isAnimated(_ text: String, effect: String = "") throws -> Bool {
    try track([(1, 3, text)], effect: effect).pictureSpan(at: 2_000).isAnimated
  }

  /// Tags that make a line change with time: a transform, a move, a fade, a
  /// karaoke sweep, in any block of the line and after any other tag.
  func testTagsThatChangeWithTimeMakeALineAnimated() throws {
    let animated = [
      "{\\t(0,500,\\fs40)}moves", "{\\t(\\fs40)}moves", "{\\move(10,10,100,100)}moves",
      "{\\move(10,10,100,100,0,500)}moves", "{\\fad(100,100)}fades",
      "{\\fade(255,0,255,0,0,500,1000)}fades", "{\\k50}sweep", "{\\kf50}sweep", "{\\ko50}sweep",
      "{\\K50}sweep", "{\\an8\\blur2\\t(\\fs40)}after others", "{\\fs20}first{\\k20}second block",
    ]
    for text in animated {
      XCTAssertTrue(try isAnimated(text), text)
    }
  }

  func testAnEffectMakesALineAnimated() throws {
    XCTAssertTrue(try isAnimated("scrolls", effect: "Scroll up;0;100;20"))
    XCTAssertTrue(try isAnimated("scrolls", effect: "Banner;50"))
  }

  func testTagsThatHoldStillLeaveALineStill() throws {
    let still = [
      "plain", "{\\an8}top", "{\\pos(100,100)}placed", "{\\blur3}soft", "{\\fnHelvetica}named",
      "{\\fnTahoma\\fsp2}named like a tag", "{\\c&HFF0000&\\3c&H00FF00&}colours", "{\\clip(0,0,100,100)}clipped",
      "{\\fr10\\fscx120}turned", "{\\r}reset", "{\\rKaraoke}reset to a style", "{\\i1\\b1}slanted",
      "two\\Nlines", "a backslash-t \\t outside a block", "{a comment with no tag in it}x",
    ]
    for text in still {
      XCTAssertFalse(try isAnimated(text), text)
    }
  }

  /// Only lines on screen count: an animated one that is over, or yet to
  /// come, does not make the picture in between animated.
  func testOnlyLinesOnScreenCountForAnimation() throws {
    let track = try track([(1, 2, "{\\fad(100,100)}over"), (2, 3, "still"), (3, 4, "{\\k20}yet to come")])
    XCTAssertTrue(track.pictureSpan(at: 1_500).isAnimated)
    XCTAssertFalse(track.pictureSpan(at: 2_500).isAnimated)
    XCTAssertTrue(track.pictureSpan(at: 3_500).isAnimated)
  }
}
