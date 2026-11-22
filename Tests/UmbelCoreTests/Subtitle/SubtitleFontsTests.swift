import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class FrozenHostClock: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// The host's fonts reach libass for the tracks showing and the ones shown
/// later, which is how a line set in a font the device lacks — and in
/// characters no system font draws — gets drawn at all.
///
/// The lines are in the Private Use Area, where only PrivateUseBoxes.ttf has
/// glyphs, on macOS; iOS offers a Last Resort glyph for any character, so the
/// tests that need one left unresolved skip there. The script names a family
/// that exists nowhere, so it is the default family that draws them.
final class SubtitleFontsTests: XCTestCase {
  private let size = CGSize(width: 320, height: 180)
  private let line = "\u{E000}\u{E001}\u{E002}\u{E003}"

  private func script(family: String = "No Such Family") -> Data {
    Data("""
      [Script Info]
      ScriptType: v4.00+
      PlayResX: 320
      PlayResY: 180

      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
      Style: Default,\(family),20,&H00FFFFFF,&H00000000,0,0,1,0,0,5,0,0,0

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:00.20,0:00:00.80,Default,,0,0,0,,\(line)
      """.utf8)
  }

  private var fonts: UmbelSubtitleFonts {
    get throws {
      let boxes = try Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fonts/PrivateUseBoxes.ttf"))
      return UmbelSubtitleFonts(fonts: [boxes], defaultFamily: "Private Use Boxes")
    }
  }

  /// The line drawn from the font the way a container's attachment supplies
  /// one, with the script naming it: what drawing it right looks like.
  private func attachedWidth() async throws -> CGFloat {
    let boxes = try XCTUnwrap(fonts.fonts.first)
    let source = try XCTUnwrap(ASSSubtitleSource(
      script: script(family: "Private Use Boxes"),
      fonts: [EmbeddedFont(name: "PrivateUseBoxes.ttf", data: boxes)]))
    return bounds(await source.render(at: time(0.5), in: size, videoSize: nil)).width
  }

  private func requireUnresolvable() async throws {
    let source = try XCTUnwrap(ASSSubtitleSource(script: script(), fonts: []))
    _ = await source.render(at: time(0.5), in: size, videoSize: nil)
    let unresolved = await source.statistics.unresolvedGlyphCount
    try XCTSkipIf(unresolved == 0, "this platform draws a Last Resort glyph for any character")
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1000)
  }

  private func bounds(_ frame: UmbelSubtitleFrame) -> CGRect {
    frame.bitmaps.map(\.frame).reduce(CGRect.null) { $0.union($1) }
  }

  // MARK: One source

  func testAFontGivenAtTheStartDrawsALineInAMissingFont() async throws {
    let source = try XCTUnwrap(ASSSubtitleSource(script: script(), fonts: [], hostFonts: fonts))
    let frame = await source.render(at: time(0.5), in: size, videoSize: nil)

    let statistics = await source.statistics
    XCTAssertEqual(statistics.unresolvedGlyphCount, 0)
    let reference = try await attachedWidth()
    XCTAssertGreaterThan(reference, 0)
    XCTAssertEqual(bounds(frame).width, reference, accuracy: 0.5, "drawn from the host's font")
  }

  func testWithoutFontsTheSameLineComesOutAsBoxesAndIsCounted() async throws {
    try await requireUnresolvable()
    let source = try XCTUnwrap(ASSSubtitleSource(script: script(), fonts: []))
    let frame = await source.render(at: time(0.5), in: size, videoSize: nil)

    let statistics = await source.statistics
    XCTAssertGreaterThan(statistics.unresolvedGlyphCount, 0)
    let reference = try await attachedWidth()
    XCTAssertGreaterThan(abs(bounds(frame).width - reference), 5, "not from the font")
  }

  /// Fonts given while the line is up: the picture cached for it must go,
  /// or the host would see no change until the line was over.
  func testFontsGivenWhileALineIsUpReplaceItsPicture() async throws {
    try await requireUnresolvable()
    let source = try XCTUnwrap(ASSSubtitleSource(script: script(), fonts: []))
    let before = await source.render(at: time(0.4), in: size, videoSize: nil)
    let unresolvedBefore = await source.statistics.unresolvedGlyphCount
    XCTAssertGreaterThan(unresolvedBefore, 0)

    await source.use(try fonts)
    let after = await source.render(at: time(0.5), in: size, videoSize: nil)
    XCTAssertTrue(after.isChanged)
    XCTAssertNotEqual(bounds(after).width, bounds(before).width)
    let reference = try await attachedWidth()
    XCTAssertEqual(bounds(after).width, reference, accuracy: 0.5)
    let unresolvedAfter = await source.statistics.unresolvedGlyphCount
    XCTAssertEqual(unresolvedAfter, unresolvedBefore, "no lookup failed since")
  }

  func testTheSameFontsGivenAgainChangeNothing() async throws {
    let source = try XCTUnwrap(ASSSubtitleSource(script: script(), fonts: [], hostFonts: fonts))
    let first = await source.render(at: time(0.4), in: size, videoSize: nil)
    await source.use(try fonts)
    let again = await source.render(at: time(0.5), in: size, videoSize: nil)

    XCTAssertFalse(again.isChanged)
    XCTAssertEqual(bounds(again), bounds(first))
    let drawn = await source.statistics.renderCount
    XCTAssertEqual(drawn, 1, "the picture was kept")
  }

  // MARK: A session

  private func session() async throws -> PlaybackSession {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/short.mp4")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: url),
      audioOutput: VirtualAudioOutput(hostTime: FrozenHostClock()), hostTime: FrozenHostClock())
    try await session.load()
    addTeardownBlock { await session.stop() }
    return session
  }

  private func showScript(in session: PlaybackSession) async throws {
    let track = try await session.addExternalSubtitle(MemorySource(data: script()))
    try await session.selectSubtitleTrack(track.id)
    try await session.seek(to: time(0.5))
  }

  func testSessionFontsReachATrackAlreadyShowing() async throws {
    try await requireUnresolvable()
    let session = try await session()
    try await showScript(in: session)
    let before = await session.renderSubtitles(in: size)
    let statisticsBefore = await session.subtitleRenderStatistics
    XCTAssertGreaterThan(statisticsBefore.unresolvedGlyphCount, 0, "no font draws it yet")

    await session.setSubtitleFonts(try fonts)
    let after = await session.renderSubtitles(in: size)
    XCTAssertTrue(after.isChanged)
    XCTAssertNotEqual(bounds(after).width, bounds(before).width)
    let reference = try await attachedWidth()
    XCTAssertEqual(bounds(after).width, reference, accuracy: 0.5)
    let statisticsAfter = await session.subtitleRenderStatistics
    XCTAssertEqual(statisticsAfter.unresolvedGlyphCount, statisticsBefore.unresolvedGlyphCount)
  }

  func testSessionFontsSetBeforeATrackIsShownReachIt() async throws {
    let session = try await session()
    await session.setSubtitleFonts(try fonts)
    try await showScript(in: session)

    let frame = await session.renderSubtitles(in: size)
    let reference = try await attachedWidth()
    XCTAssertEqual(bounds(frame).width, reference, accuracy: 0.5)
    let statistics = await session.subtitleRenderStatistics
    XCTAssertEqual(statistics.unresolvedGlyphCount, 0)
  }

  func testTheSessionReportsTheFontsItWasGiven() async throws {
    let session = try await session()
    let none = await session.subtitleFonts
    XCTAssertEqual(none, UmbelSubtitleFonts())
    let given = try fonts
    await session.setSubtitleFonts(given)
    let reported = await session.subtitleFonts
    XCTAssertEqual(reported, given)
  }

  /// The totals belong to the session, not to the track shown: switching away
  /// does not take its drawings out of them.
  func testStatisticsOutliveTheTrackThatMadeThem() async throws {
    let session = try await session()
    try await showScript(in: session)
    _ = await session.renderSubtitles(in: size)
    let shown = await session.subtitleRenderStatistics
    XCTAssertGreaterThan(shown.renderCount, 0)
    XCTAssertGreaterThan(shown.longestRender, 0)

    try await session.selectSubtitleTrack(nil)
    let after = await session.subtitleRenderStatistics
    XCTAssertEqual(after, shown)
  }
}
