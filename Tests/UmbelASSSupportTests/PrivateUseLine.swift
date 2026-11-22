import XCTest
@testable import UmbelASSSupport

/// A line in the Private Use Area, for tests of characters no font covers.
///
/// PrivateUseBoxes.ttf has glyphs for the four characters, and no system font
/// does. Where CoreText offers its Last Resort font, which has a box for every
/// code point, libass finds a glyph anyway and nothing is left unresolved:
/// that is iOS. Tests that need a character to go unresolved skip there.
enum PrivateUseLine {
  static let text = "\u{E000}\u{E001}\u{E002}\u{E003}"
  static let family = "Private Use Boxes"

  /// An ASS script of one event, from 1 s to 3 s, in 320 × 180.
  static func script(font: String) -> Data {
    Data("""
      [Script Info]
      ScriptType: v4.00+
      PlayResX: 320
      PlayResY: 180

      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
      Style: Default,\(font),20,&H00FFFFFF,&H00000000,0,0,1,0,0,5,0,0,0

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,\(text)
      """.utf8)
  }

  static func boxesFont(file: String = #filePath) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: file)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/fonts/PrivateUseBoxes.ttf"))
  }

  static func width(_ frame: ASSFrame) -> CGFloat {
    frame.images.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      .reduce(CGRect.null) { $0.union($1) }.width
  }

  /// Skips the test where this platform draws some glyph for the line even
  /// with no font that has it.
  static func requireUnresolvable() throws {
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: script(font: "No Such Family")))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    let frame = renderer.render(track, atMilliseconds: 1_500)
    try XCTSkipIf(frame.unresolvedGlyphCount == 0,
                  "this platform draws a Last Resort glyph for any character")
  }
}
