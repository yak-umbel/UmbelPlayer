import XCTest
@testable import UmbelASSSupport

/// A script names the fonts it was written for, and the device may lack them.
/// libass then falls back to a default family, which decides whether
/// the characters of the line can be drawn at all: a Latin default has none
/// of a Chinese line's.
///
/// The line is in the Private Use Area, where only PrivateUseBoxes.ttf has
/// glyphs; its boxes are of different widths, so a line's width shows which
/// font drew it. See `PrivateUseLine`.
final class DefaultFamilyTests: XCTestCase {
  private func library() throws -> ASSLibrary {
    let library = ASSLibrary()
    library.addFont(named: "PrivateUseBoxes.ttf", data: try PrivateUseLine.boxesFont())
    return library
  }

  private func track(font: String, in library: ASSLibrary) throws -> ASSTrack {
    try XCTUnwrap(ASSTrack(library: library, scriptData: PrivateUseLine.script(font: font)))
  }

  /// The line set in the font by its own name: what drawing it right looks like.
  private func namedWidth() throws -> CGFloat {
    let library = try library()
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    return PrivateUseLine.width(renderer.render(
      try track(font: PrivateUseLine.family, in: library), atMilliseconds: 1_500))
  }

  func testALineInAMissingFontIsDrawnFromTheDefaultFamily() throws {
    let library = try library()
    let renderer = ASSRenderer(library: library, defaultFamily: PrivateUseLine.family)
    renderer.setFrameSize(width: 320, height: 180)

    let frame = renderer.render(try track(font: "No Such Family", in: library), atMilliseconds: 1_500)
    XCTAssertEqual(frame.unresolvedGlyphCount, 0)
    XCTAssertGreaterThan(PrivateUseLine.width(frame), 0)
    XCTAssertEqual(PrivateUseLine.width(frame), try namedWidth(), accuracy: 0.5, "drawn from that font")
  }

  /// A font that is in the library but named by nobody is not used for lines
  /// in other fonts: without a default family it is just another font. The
  /// characters come out as the fallback font's empty boxes, of another width.
  func testWithoutADefaultFamilyAFontNobodyNamedIsNotUsed() throws {
    try PrivateUseLine.requireUnresolvable()
    let library = try library()
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)

    let frame = renderer.render(try track(font: "No Such Family", in: library), atMilliseconds: 1_500)
    XCTAssertGreaterThan(frame.unresolvedGlyphCount, 0)
    XCTAssertGreaterThan(abs(PrivateUseLine.width(frame) - (try namedWidth())), 5, "not drawn from the font")
  }

  /// Fonts arrive while a track is up, and what is drawn then has to follow.
  func testAFamilySetAfterTheFirstDrawingTakesEffect() throws {
    try PrivateUseLine.requireUnresolvable()
    let library = try library()
    let track = try track(font: "No Such Family", in: library)
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    let before = renderer.render(track, atMilliseconds: 1_500)
    XCTAssertGreaterThan(before.unresolvedGlyphCount, 0)

    renderer.defaultFamily = PrivateUseLine.family
    let after = renderer.render(track, atMilliseconds: 1_600)
    XCTAssertEqual(after.unresolvedGlyphCount, 0)
    XCTAssertEqual(PrivateUseLine.width(after), try namedWidth(), accuracy: 0.5)
    XCTAssertTrue(after.isChanged)
  }

  /// A font added to the library after the renderer exists is found by the
  /// next reload, which the family setting does.
  func testAFontAddedLaterIsFoundOnceTheFamilyIsSet() throws {
    try PrivateUseLine.requireUnresolvable()
    let library = ASSLibrary()
    let track = try track(font: "No Such Family", in: library)
    let renderer = ASSRenderer(library: library)
    renderer.setFrameSize(width: 320, height: 180)
    XCTAssertGreaterThan(renderer.render(track, atMilliseconds: 1_500).unresolvedGlyphCount, 0)

    library.addFont(named: "PrivateUseBoxes.ttf", data: try PrivateUseLine.boxesFont())
    renderer.defaultFamily = PrivateUseLine.family
    let frame = renderer.render(track, atMilliseconds: 1_600)
    XCTAssertEqual(frame.unresolvedGlyphCount, 0)
    XCTAssertEqual(PrivateUseLine.width(frame), try namedWidth(), accuracy: 0.5)
  }
}
