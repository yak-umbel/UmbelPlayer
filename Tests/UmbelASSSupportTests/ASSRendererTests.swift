import XCTest
@testable import UmbelASSSupport

final class ASSRendererTests: XCTestCase {
  /// A script whose coordinates match the frame: 320 × 180, so positions in
  /// the script are positions in the output.
  private let script = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
    Style: Default,Helvetica,20,&H00FFFFFF,&H00000000,0,0,1,1,0,5,0,0,0

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\pos(80,40)}placed
    Dialogue: 0,0:00:05.00,0:00:07.00,Default,,0,0,0,,{\\pos(200,120)}placed
    """

  private func renderer(width: Int = 320, height: Int = 180) -> ASSRenderer {
    let renderer = ASSRenderer(library: ASSLibrary())
    renderer.setFrameSize(width: width, height: height)
    return renderer
  }

  /// Everything drawn, as one rectangle.
  private func bounds(of images: [ASSImage]) -> CGRect {
    images.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      .reduce(CGRect.null) { $0.union($1) }
  }

  /// `\pos` is libass's own: the CoreText path ignores it. The same words
  /// at two positions move by exactly the difference, which is what proves
  /// libass drew them.
  ///
  /// Relative, not absolute: libass centres the text's layout box on the
  /// point — advance widths across, ascender to descender down — and the ink
  /// sits a few pixels off it. The absolute checks only say "about here".
  func testPositionTagPlacesTheText() throws {
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data(script.utf8)))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)

    let first = bounds(of: renderer.render(track, atMilliseconds: 1_500).images)
    let second = bounds(of: renderer.render(track, atMilliseconds: 5_500).images)
    XCTAssertFalse(first.isNull)
    XCTAssertEqual(first.midX, 80, accuracy: 5)
    XCTAssertEqual(second.minX - first.minX, 120, accuracy: 1)
    XCTAssertEqual(second.minY - first.minY, 80, accuracy: 1)
  }

  /// Ordinary dialogue grows with the font scale. Positioned effect text
  /// keeps the script's authored dimensions.
  func testTheFontScaleMakesTheTextTaller() throws {
    let library = ASSLibrary()
    let dialogue = script.replacingOccurrences(of: "{\\pos(80,40)}", with: "")
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data(dialogue.utf8)))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    let plain = bounds(of: renderer.render(track, atMilliseconds: 1_500).images)
    renderer.setFontScale(2)
    let scaled = bounds(of: renderer.render(track, atMilliseconds: 1_500).images)
    XCTAssertGreaterThan(scaled.width, plain.width * 1.8)
  }

  func testNothingOutsideTheEvent() throws {
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data(script.utf8)))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    XCTAssertTrue(renderer.render(track, atMilliseconds: 500).images.isEmpty)
    XCTAssertTrue(renderer.render(track, atMilliseconds: 3_000).images.isEmpty, "end is exclusive")
  }

  /// Rendering the same moment twice reports no change, so callers can skip
  /// compositing again.
  func testRepeatReportsNoChange() throws {
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data(script.utf8)))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    XCTAssertTrue(renderer.render(track, atMilliseconds: 1_500).isChanged)
    XCTAssertFalse(renderer.render(track, atMilliseconds: 1_600).isChanged)
  }

  /// An embedded track receives its header once and events packet by packet,
  /// in the Matroska block format — which is what MKV stores.
  func testChunksFromAContainer() throws {
    let library = ASSLibrary()
    let track = ASSTrack(library: library)
    let header = script.components(separatedBy: "[Events]")[0]
      + "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    track.processCodecPrivate(Data(header.utf8))
    track.processChunk(
      Data("0,0,Default,,0,0,0,,{\\pos(240,120)}chunk".utf8),
      startMilliseconds: 4_000, durationMilliseconds: 1_000)

    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    let frame = renderer.render(track, atMilliseconds: 4_500)
    let drawn = bounds(of: frame.images)
    XCTAssertEqual(drawn.midX, 240, accuracy: 5)
    XCTAssertEqual(drawn.midY, 120, accuracy: 12, "the layout box, not the ink, is centred")
    XCTAssertTrue(renderer.render(track, atMilliseconds: 5_000).images.isEmpty, "duration is the end")
  }

  /// libass colours are RGBA with the last byte as transparency.
  func testColourCarriesTransparency() throws {
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data(script.utf8)))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    let images = renderer.render(track, atMilliseconds: 1_500).images
    // The fill is white and opaque; the outline black and opaque.
    XCTAssertTrue(images.contains { $0.color == 0xFFFF_FF00 })
    XCTAssertTrue(images.contains { $0.color == 0x0000_0000 })
  }
}
