import XCTest
@testable import UmbelASSSupport

/// Characters no usable font covers are the expensive case for libass, and
/// the one that shows as empty boxes. A frame says how many lookups it gave
/// up on, so that a caller can tell a font problem from a slow device.
///
/// The line is set in the Private Use Area, which no macOS system font covers;
/// PrivateUseBoxes.ttf is the one font that does. See `PrivateUseLine`.
final class UnresolvedGlyphTests: XCTestCase {
  private func render(font: String, library: ASSLibrary, at time: Int64 = 1_500) throws -> ASSFrame {
    let track = try XCTUnwrap(ASSTrack(library: library, scriptData: PrivateUseLine.script(font: font)))
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    return renderer.render(track, atMilliseconds: time)
  }

  func testACharacterNoFontCoversIsCounted() throws {
    try PrivateUseLine.requireUnresolvable()
    let frame = try render(font: PrivateUseLine.family, library: ASSLibrary())
    XCTAssertGreaterThanOrEqual(frame.unresolvedGlyphCount, 4, "one lookup per character, at least")
  }

  func testAFontThatCoversThemLeavesNoneUnresolved() throws {
    let library = ASSLibrary()
    library.addFont(named: "PrivateUseBoxes.ttf", data: try PrivateUseLine.boxesFont())
    let frame = try render(font: PrivateUseLine.family, library: library)
    XCTAssertEqual(frame.unresolvedGlyphCount, 0)
    XCTAssertFalse(frame.images.isEmpty, "drawn from the font")
  }

  /// A count that only grew would make every later frame look as broken as
  /// the first. Each frame reports its own.
  func testTheCountBelongsToTheFrameThatProducedIt() throws {
    try PrivateUseLine.requireUnresolvable()
    let library = ASSLibrary()
    let broken = try render(font: PrivateUseLine.family, library: library)
    library.addFont(named: "PrivateUseBoxes.ttf", data: try PrivateUseLine.boxesFont())
    let repaired = try render(font: PrivateUseLine.family, library: library)
    XCTAssertGreaterThan(broken.unresolvedGlyphCount, 0)
    XCTAssertEqual(repaired.unresolvedGlyphCount, 0)
  }

  func testAFrameSaysHowLongItTook() throws {
    let frame = try render(font: PrivateUseLine.family, library: ASSLibrary())
    XCTAssertGreaterThan(frame.renderDuration, 0)
    XCTAssertLessThan(frame.renderDuration, 5)
  }
}
