import CoreText
import XCTest
@testable import UmbelCore

/// Finding a font by family name is slow and cues ask for the same few names
/// again and again, so each name is looked up once.
final class SubtitleFontLookupTests: XCTestCase {
  func testTheSameNameGivesTheSameFontWithoutAnotherLookup() {
    let first = SubtitleRasterizer.probeFont(named: "Helvetica")
    let second = SubtitleRasterizer.probeFont(named: "Helvetica")
    XCTAssertTrue(first === second, "looked up once")
    XCTAssertEqual(CTFontCopyFamilyName(first) as String, "Helvetica")
  }

  func testAnUnknownNameFallsBackToTheSystemFont() {
    let font = SubtitleRasterizer.probeFont(named: "No Such Family 1234")
    let system = SubtitleRasterizer.probeFont(named: nil)
    XCTAssertEqual(CTFontCopyFamilyName(font) as String, CTFontCopyFamilyName(system) as String)
  }
}
