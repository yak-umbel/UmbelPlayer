import XCTest
@testable import UmbelASSSupport

/// Fonts carried in a script's own [Fonts] section, rather than beside it as
/// a container's attachments.
///
/// The line is drawn in Silkscreen, which the system does not have. With the
/// script's font it comes out exactly as wide as with the same font added
/// the way attachments are; without it, libass falls back to another font of
/// another width.
final class ScriptFontTests: XCTestCase {
  private let styles = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 180

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, OutlineColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV
    Style: Default,Silkscreen,20,&H00FFFFFF,&H00000000,0,0,1,0,0,5,0,0,0

    """

  private let events = """
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Embedded font

    """

  private func font() throws -> Data {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/fonts/Silkscreen-Regular.ttf")
    return try Data(contentsOf: fixture)
  }

  /// A [Fonts] section as scripts carry one: every three bytes as four
  /// characters of six bits plus 33, a short last group as one character
  /// more than its bytes, eighty characters to a line.
  private func fontsSection(named name: String, _ data: Data) -> String {
    let bytes = [UInt8](data)
    var encoded: [UInt8] = []
    for start in stride(from: 0, to: bytes.count, by: 3) {
      let group = bytes[start..<min(start + 3, bytes.count)]
      var value: UInt32 = 0
      for (offset, byte) in group.enumerated() { value |= UInt32(byte) << (16 - 8 * offset) }
      for position in 0...group.count {
        encoded.append(UInt8((value >> (18 - 6 * position)) & 63) + 33)
      }
    }
    var lines = ["[Fonts]", "fontname: \(name)"]
    for start in stride(from: 0, to: encoded.count, by: 80) {
      lines.append(String(decoding: encoded[start..<min(start + 80, encoded.count)], as: UTF8.self))
    }
    return lines.joined(separator: "\n") + "\n\n"
  }

  private func width(of track: ASSTrack, library: ASSLibrary) -> CGFloat {
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    return renderer.render(track, atMilliseconds: 1_500).images
      .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
      .reduce(CGRect.null) { $0.union($1) }.width
  }

  /// The width with the font added as an attachment is: the reference.
  private func attachedWidth() throws -> CGFloat {
    let library = ASSLibrary()
    library.addFont(named: "Silkscreen-Regular.ttf", data: try font())
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data((styles + events).utf8)))
    return width(of: track, library: library)
  }

  private func fallbackWidth() throws -> CGFloat {
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data((styles + events).utf8)))
    return width(of: track, library: library)
  }

  func testTheReferenceWidthsDiffer() throws {
    let attached = try attachedWidth()
    let fallback = try fallbackWidth()
    XCTAssertGreaterThan(attached, 0)
    XCTAssertGreaterThan(fallback, 0)
    XCTAssertNotEqual(attached, fallback, accuracy: 2)
  }

  /// An external script: its [Fonts] section is read with the rest of it.
  func testAScriptsOwnFontIsUsed() throws {
    let script = styles + fontsSection(named: "Silkscreen-Regular.ttf", try font()) + events
    let library = ASSLibrary()
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: Data(script.utf8)))
    XCTAssertEqual(width(of: track, library: library), try attachedWidth())
  }

  /// A track in a container: its header, which holds everything before
  /// [Events], can carry the section too.
  func testAFontInAContainersHeaderIsUsed() throws {
    let header = styles + fontsSection(named: "Silkscreen-Regular.ttf", try font())
      + "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
    let library = ASSLibrary()
    let track = ASSTrack(library: library)
    track.processCodecPrivate(Data(header.utf8))
    track.processChunk(
      Data("0,0,Default,,0,0,0,,Embedded font".utf8),
      startMilliseconds: 1_000, durationMilliseconds: 2_000)
    XCTAssertEqual(width(of: track, library: library), try attachedWidth())
  }
}
