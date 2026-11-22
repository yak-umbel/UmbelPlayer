import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

/// A display asks for the subtitle picture on every tick, 120 times a second
/// on a fast panel, and a line stays up for seconds. libass lays the line out
/// again on every call, so the source draws a picture once and hands the same
/// one back until something that can change it happens: an event starting or
/// ending, a new size or scale, or, for lines that move, a step of time.
///
/// Drawings are counted through the source's statistics.
final class ASSSubtitleSourceTests: XCTestCase {
  private let size = CGSize(width: 640, height: 360)
  private let track = UmbelTrack.ID(rawValue: 3)

  private let header = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
    Style: Default,Helvetica,28,&H00FFFFFF,&H00000000,0,0,1,1,0,2,10,10,20

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

  private func source() -> ASSSubtitleSource {
    ASSSubtitleSource(header: header, fonts: [])
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(value: Int64((seconds * 1000).rounded()), timescale: 1000)
  }

  /// One event as an MKV block holds it.
  private func event(
    _ order: Int, from start: Double, for duration: Double, _ text: String, effect: String = ""
  ) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data("\(order),0,Default,,0,0,0,\(effect),\(text)".utf8),
      presentationTime: time(start), decodeTime: time(start), duration: time(duration),
      isKeyframe: true)
  }

  /// The moments a display running at `rate` Hz asks, from `start` up to
  /// but not including `end`.
  private func ticks(from start: Double, to end: Double, rate: Double = 120) -> [Double] {
    var moments: [Double] = []
    var index = 0.0
    while start + index / rate < end - 1e-9 {
      moments.append(start + index / rate)
      index += 1
    }
    return moments
  }

  @discardableResult
  private func ask(
    _ source: ASSSubtitleSource, at seconds: Double, in frame: CGSize? = nil, scale: Double = 1
  ) async -> UmbelSubtitleFrame {
    await source.render(at: time(seconds), in: frame ?? size, videoSize: nil, scale: scale)
  }

  private func askEvery(
    tick moments: [Double], _ source: ASSSubtitleSource
  ) async -> [UmbelSubtitleFrame] {
    var frames: [UmbelSubtitleFrame] = []
    for moment in moments { frames.append(await ask(source, at: moment)) }
    return frames
  }

  private func drawings(_ source: ASSSubtitleSource) async -> Int {
    await source.statistics.renderCount
  }

  private func bounds(_ frame: UmbelSubtitleFrame) -> CGRect {
    frame.bitmaps.map(\.frame).reduce(CGRect.null) { $0.union($1) }
  }

  // MARK: Lines that stay put

  /// Three seconds of a 120 Hz display: 360 questions, one drawing.
  func testALineThatStaysPutIsDrawnOnceHoweverOftenItIsAskedFor() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 3, "Still line"))
    let frames = await askEvery(tick: ticks(from: 1, to: 4), source)

    XCTAssertEqual(frames.count, 360)
    let drawn = await drawings(source)
    XCTAssertEqual(drawn, 1)
    XCTAssertTrue(frames[0].isChanged)
    XCTAssertFalse(frames[0].bitmaps.isEmpty)
    XCTAssertTrue(frames.dropFirst().allSatisfy { !$0.isChanged })
    XCTAssertTrue(frames.dropFirst().allSatisfy { frame in
      zip(frame.bitmaps, frames[0].bitmaps).allSatisfy { $0.image === $1.image }
    }, "the very same images each time")
  }

  func testTheLineEndingIsOneMoreDrawingAndLeavesNothing() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 3, "Still line"))
    _ = await askEvery(tick: ticks(from: 1, to: 4), source)
    let after = await askEvery(tick: ticks(from: 4, to: 4.5), source)

    let drawn = await drawings(source)
    XCTAssertEqual(drawn, 2)
    XCTAssertTrue(after[0].isChanged)
    XCTAssertTrue(after.allSatisfy { $0.bitmaps.isEmpty })
    XCTAssertTrue(after.dropFirst().allSatisfy { !$0.isChanged })
  }

  /// Nothing on screen is also a picture that holds until the next event.
  func testEachEventBoundaryCostsOneDrawing() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 1, "first"))
    await source.feed(event(1, from: 2, for: 1, "second"))   // starts as the first ends
    await source.feed(event(2, from: 4, for: 1, "third"))    // after a gap
    _ = await askEvery(tick: ticks(from: 0.5, to: 5.5), source)

    // Empty until 1, first, second, empty until 4, third, empty again.
    let drawn = await drawings(source)
    XCTAssertEqual(drawn, 6)
  }

  func testAskingAgainAtAnEarlierMomentInTheSamePictureIsFree() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 3, "Still line"))
    let later = await ask(source, at: 3)
    let earlier = await ask(source, at: 1.5)

    let drawn = await drawings(source)
    XCTAssertEqual(drawn, 1)
    XCTAssertFalse(earlier.isChanged)
    XCTAssertTrue(zip(later.bitmaps, earlier.bitmaps).allSatisfy { $0.image === $1.image })
  }

  func testSeekingToAnotherPictureDrawsIt() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 3, "Still line"))
    await source.feed(event(1, from: 10, for: 2, "Later line"))
    let first = await ask(source, at: 2)
    let before = await ask(source, at: 0.5)
    let later = await ask(source, at: 11)

    let drawn = await drawings(source)
    XCTAssertEqual(drawn, 3)
    XCTAssertFalse(first.bitmaps.isEmpty)
    XCTAssertTrue(before.bitmaps.isEmpty)
    XCTAssertFalse(later.bitmaps.isEmpty)
  }

  // MARK: What does change the picture

  func testANewSizeDrawsAgainOnceAndANewScaleDrawsAgainOnce() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 5, "Still line"))
    let small = await ask(source, at: 2)
    var drawn = await drawings(source)
    XCTAssertEqual(drawn, 1)

    let big = CGSize(width: 1280, height: 720)
    for moment in ticks(from: 2, to: 2.5) { await ask(source, at: moment, in: big) }
    drawn = await drawings(source)
    XCTAssertEqual(drawn, 2, "a new size")
    let resized = await ask(source, at: 2.6, in: big)
    XCTAssertEqual(bounds(resized).width / bounds(small).width, 2, accuracy: 0.1)

    for moment in ticks(from: 3, to: 3.5) { await ask(source, at: moment, in: big, scale: 2) }
    drawn = await drawings(source)
    XCTAssertEqual(drawn, 3, "a new scale")
    let scaled = await ask(source, at: 3.6, in: big, scale: 2)
    XCTAssertGreaterThan(bounds(scaled).width, bounds(resized).width * 1.5)
  }

  /// A packet arrives for a stretch already on screen: a line that overlaps
  /// the picture shown has to join it, though nothing else has changed.
  func testAnEventFedIntoThePictureOnScreenIsPickedUp() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 5, "Long line"))
    let alone = await ask(source, at: 2)
    await source.feed(event(1, from: 3, for: 1, "Joins the first"))
    let early = await ask(source, at: 2.5)
    let joined = await ask(source, at: 3.5)

    XCTAssertFalse(early.isChanged, "the new line has not started")
    XCTAssertGreaterThan(bounds(joined).height, bounds(alone).height * 1.5, "two lines now")
    XCTAssertTrue(joined.isChanged)
  }

  func testAnEventFedBeyondThePictureOnScreenCostsNothing() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 1, "Short line"))
    _ = await ask(source, at: 1.5)
    await source.feed(event(1, from: 10, for: 1, "Far away"))
    let again = await ask(source, at: 1.6)

    let drawn = await drawings(source)
    XCTAssertEqual(drawn, 1)
    XCTAssertFalse(again.isChanged)
  }

  /// With nothing known after the picture, a packet that starts later still
  /// has to end it: the empty picture only lasts until the new line.
  func testALineFedWhileTheScreenIsEmptyAppearsOnTime() async {
    let source = source()
    let empty = await ask(source, at: 1)
    await source.feed(event(0, from: 2, for: 1, "Arrives early"))
    let still = await ask(source, at: 1.5)
    let shown = await ask(source, at: 2.5)

    XCTAssertTrue(empty.bitmaps.isEmpty)
    XCTAssertTrue(still.bitmaps.isEmpty)
    XCTAssertFalse(shown.bitmaps.isEmpty)
    XCTAssertTrue(shown.isChanged)
  }

  // MARK: Reusing a picture never shows a wrong one

  private func pixels(of frame: UmbelSubtitleFrame) -> [Data] {
    frame.bitmaps.map { bitmap in
      (bitmap.image.dataProvider?.data as Data?) ?? Data()
    }
  }

  /// The reference for everything above: a source that has drawn nothing
  /// before cannot reuse anything. Whatever moment the display asks about,
  /// in whatever order — forwards, jumping back, jumping far — the source
  /// that reuses pictures must show exactly what the fresh one draws.
  func testReusedPicturesAreTheOnesALookFromScratchWouldDraw() async {
    let events: [(Double, Double, String)] = [
      (0.5, 4, "{\\an8}Overlaps the next"), (2, 6, "Long line"), (2, 3, "{\\pos(300,120)}Same start"),
      (5, 5.5, "Brief"), (8, 12, "{\\blur2}Soft"), (8, 9, "Together with Soft"),
      (11, 11, "Never shown"), (14, 20, "Alone"), (14.5, 15, "{\\c&H0000FF&}Red"),
    ]
    let reusing = source()
    var packets: [DemuxPacket] = []
    for (index, event) in events.enumerated() {
      packets.append(self.event(index, from: event.0, for: event.1 - event.0, event.2))
    }
    for packet in packets { await reusing.feed(packet) }

    var generator = SystemRandomNumberGenerator()
    var seed: UInt64 = 0x5EED
    func next() -> Double {                         // fixed sequence, so a failure repeats
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Double(seed >> 33) / Double(1 << 31)
    }
    _ = generator.next()
    var wrong: [Double] = []
    for _ in 0..<300 {
      let moment = (next() * 22 * 1000).rounded() / 1000
      let fresh = source()
      for packet in packets { await fresh.feed(packet) }
      let expected = await ask(fresh, at: moment)
      let actual = await ask(reusing, at: moment)
      if actual.bitmaps.map(\.frame) != expected.bitmaps.map(\.frame) || pixels(of: actual) != pixels(of: expected) {
        wrong.append(moment)
      }
    }
    XCTAssertEqual(wrong, [], "moments where the reused picture differs from a fresh drawing")
    let drawn = await drawings(reusing)
    XCTAssertLessThan(drawn, 300, "and it did reuse")
  }

  // MARK: Lines that move

  /// A fade, a move or a karaoke sweep changes the picture with time, which
  /// the source cannot know ahead, so it draws them again — but as often as
  /// a video can show a new picture, not as often as a panel refreshes.
  func testAFadingLineIsDrawnAtMostOncePerStepOfTime() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 3, "{\\fad(800,800)}Fading line"))
    let frames = await askEvery(tick: ticks(from: 1, to: 2), source)    // 120 questions, one second

    let drawn = await drawings(source)
    XCTAssertLessThanOrEqual(drawn, 64, "about 60 a second, never one per tick")
    XCTAssertGreaterThanOrEqual(drawn, 50, "and still moving")
    let changes = frames.filter(\.isChanged).count
    XCTAssertGreaterThan(changes, 20, "the fade is seen as a fade")
  }

  /// What is shown is what libass draws at a moment the display asked about,
  /// not an approximation: the first picture of each step is a real frame.
  func testAMovingLineIsAtThePlaceLibassPutsItAtThatMoment() async throws {
    let moving = "{\\move(100,100,500,100,0,3000)}Moving line"
    let animated = source()
    await animated.feed(event(0, from: 1, for: 3, moving))
    let frames = await askEvery(tick: ticks(from: 1, to: 3), animated)

    // The line crosses 400 pixels in 3 s; the picture at 2.5 s is where it
    // was drawn after 1.5 s, give or take the step.
    let late = try XCTUnwrap(frames.last)
    let reference = source()
    await reference.feed(event(0, from: 1, for: 3, moving))
    let exact = await ask(reference, at: 3 - 1.0 / 120)
    XCTAssertEqual(bounds(late).minX, bounds(exact).minX, accuracy: 400 * 0.017 / 3 + 1)
  }

  func testAMovingLineIsDrawnAgainWhenTimeGoesBack() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 3, "{\\move(100,100,500,100,0,3000)}Moving line"))
    let late = await ask(source, at: 3)
    let early = await ask(source, at: 1.5)

    XCTAssertTrue(early.isChanged)
    XCTAssertLessThan(bounds(early).minX, bounds(late).minX)
  }

  /// A line that moves does not drag the others into redrawing: once it is
  /// gone, the picture holds again.
  func testAfterTheMovingLineEndsThePictureHolds() async {
    let source = source()
    await source.feed(event(0, from: 1, for: 1, "{\\fad(300,300)}Brief"))
    await source.feed(event(1, from: 2, for: 3, "Plain"))
    _ = await askEvery(tick: ticks(from: 1, to: 2), source)
    let whileMoving = await drawings(source)
    _ = await askEvery(tick: ticks(from: 2, to: 5), source)

    let drawn = await drawings(source)
    XCTAssertEqual(drawn, whileMoving + 1, "one drawing for the plain line, then nothing")
  }
}
