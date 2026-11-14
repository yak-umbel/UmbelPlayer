import CoreMedia
import XCTest
@testable import UmbelCore

final class ASSDialogueTests: XCTestCase {
  private let sheet = ASSStyleSheet(header: """
    [Script Info]
    PlayResX: 384
    PlayResY: 288

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, Outline, Alignment, MarginL, MarginR, MarginV
    Style: Default,Arial,16,&H00FFFFFF,&H00000000,0,0,1,2,10,10,10
    Style: Top,Arial,24,&H0000FFFF,&H00000000,-1,0,2,8,20,20,30
    """)

  private func cue(_ line: String) -> UmbelSubtitleCue {
    ASSDialogue.cue(
      from: line, styles: sheet,
      start: CMTime(seconds: 1, preferredTimescale: 1000),
      end: CMTime(seconds: 2, preferredTimescale: 1000))
  }

  func testPlainLineTakesTheStyle() {
    let cue = cue("0,0,Default,,0,0,0,,hello")
    XCTAssertEqual(cue.plainText, "hello")
    XCTAssertEqual(cue.alignment, .bottomCenter)
    XCTAssertEqual(cue.relativeFontSize, 16.0 / 288, accuracy: 1e-9)
    XCTAssertEqual(cue.margins.vertical, 10.0 / 288, accuracy: 1e-9)
    XCTAssertEqual(cue.margins.left, 10.0 / 384, accuracy: 1e-9)
    XCTAssertEqual(cue.relativeOutlineWidth, 1.0 / 288, accuracy: 1e-9)
    XCTAssertEqual(cue.runs.count, 1)
    XCTAssertFalse(cue.runs[0].isItalic)
  }

  /// Only the first eight commas separate fields; the text keeps the rest.
  func testCommasInTheTextSurvive() {
    XCTAssertEqual(cue("0,0,Default,,0,0,0,,one, two, three").plainText, "one, two, three")
  }

  func testNamedStyleApplies() {
    let cue = cue("0,0,Top,,0,0,0,,sign")
    XCTAssertEqual(cue.alignment, .topCenter)
    XCTAssertTrue(cue.runs[0].isBold)
    XCTAssertEqual(cue.runs[0].color, UmbelColor(red: 1, green: 1, blue: 0, alpha: 1))
    XCTAssertEqual(cue.margins.vertical, 30.0 / 288, accuracy: 1e-9)
  }

  /// A non-zero margin on the line overrides the style's.
  func testLineMarginsOverrideTheStyle() {
    let cue = cue("0,0,Default,,0,0,50,,x")
    XCTAssertEqual(cue.margins.vertical, 50.0 / 288, accuracy: 1e-9)
    XCTAssertEqual(cue.margins.left, 10.0 / 384, accuracy: 1e-9)
  }

  func testOverrideTagsSplitIntoRuns() {
    let cue = cue(#"0,0,Default,,0,0,0,,plain {\i1}italic{\i0} {\b1\u1}bold{\r}back"#)
    XCTAssertEqual(cue.plainText, "plain italic boldback")
    XCTAssertEqual(cue.runs.map(\.text), ["plain ", "italic", " ", "bold", "back"])
    XCTAssertEqual(cue.runs.map(\.isItalic), [false, true, false, false, false])
    XCTAssertEqual(cue.runs.map(\.isBold), [false, false, false, true, false])
    XCTAssertTrue(cue.runs[3].isUnderlined)
  }

  func testColourAndAlphaTags() {
    let cue = cue(#"0,0,Default,,0,0,0,,{\c&H0000FF&}red{\1c&HFF0000&\alpha&H80&}blue"#)
    XCTAssertEqual(cue.runs[0].color, UmbelColor(red: 1, green: 0, blue: 0, alpha: 1))
    XCTAssertEqual(cue.runs[1].color.blue, 1)
    XCTAssertEqual(cue.runs[1].color.alpha, Double(0x7F) / 255, accuracy: 1e-9)
  }

  func testLineBreaksAndHardSpaces() {
    XCTAssertEqual(cue(#"0,0,Default,,0,0,0,,one\Ntwo\nthree\hfour"#).plainText,
                   "one\ntwo three\u{00A0}four")
  }

  /// The first \an wins; later ones are ignored, as the reference renderer does.
  func testFirstAlignmentTagWins() {
    XCTAssertEqual(cue(#"0,0,Default,,0,0,0,,{\an8}top{\an1}still top"#).alignment, .topCenter)
    XCTAssertEqual(cue(#"0,0,Default,,0,0,0,,{\a6}legacy"#).alignment, .topCenter)
  }

  /// Unsupported tags are dropped; their text is kept. Losing a style is
  /// acceptable, losing words is not.
  func testUnknownTagsAreDroppedNotTheText() {
    let cue = cue(#"0,0,Default,,0,0,0,,{\pos(10,20)\t(0,500,\fscx120)\fad(100,100)}moving{\k20}ka"#)
    XCTAssertEqual(cue.plainText, "movingka")
  }

  /// Tags inside a transform describe where an animation ends, not how the
  /// text starts. Split at the inner backslash, `\1c` would leak out and turn
  /// the whole line to its end colour.
  func testTagsInsideATransformDoNotApply() {
    let cue = cue(#"0,0,Default,,0,0,0,,{\t(0,500,\1c&H0000FF&\fscx120)}fading"#)
    XCTAssertEqual(cue.runs[0].color, .white)
  }

  /// Drawing mode holds vector commands, not words; showing them would put
  /// "m 0 0 l 100 0" on screen.
  func testDrawingModeHidesItsCommands() {
    XCTAssertEqual(cue(#"0,0,Default,,0,0,0,,{\p1}m 0 0 l 100 0{\p0}after"#).plainText, "after")
  }

  func testUnclosedBraceIsText() {
    XCTAssertEqual(cue("0,0,Default,,0,0,0,,a { b").plainText, "a { b")
  }

  /// Not every producer writes nine fields; fewer means the whole line is text.
  func testShortLineIsTreatedAsText() {
    let cue = cue("just text")
    XCTAssertEqual(cue.plainText, "just text")
    XCTAssertEqual(cue.alignment, .bottomCenter)
  }
}
