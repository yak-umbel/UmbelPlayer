import XCTest
@testable import UmbelASSSupport

/// libass says its version as a number, 0x01705000 for 0.17.5: digits read
/// as one for the major version, two for the minor, two for the patch.
final class ASSLibraryVersionTests: XCTestCase {
  func testTheNumberReadsAsItsDigits() {
    XCTAssertEqual(ASSLibrary.version(fromNumber: 0x0170_5000), "0.17.5")
    XCTAssertEqual(ASSLibrary.version(fromNumber: 0x0150_2000), "0.15.2")
    XCTAssertEqual(ASSLibrary.version(fromNumber: 0x0130_0001), "0.13.0")
  }

  /// The one loaded is the one Tools/BuildLibass/VERSIONS pins.
  func testTheLoadedLibraryIsThePinnedOne() throws {
    XCTAssertEqual(ASSLibrary.version, try pinnedVersion())
  }

  private func pinnedVersion() throws -> String {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Tools/BuildLibass/VERSIONS")
    let line = try XCTUnwrap(
      try String(contentsOf: file, encoding: .utf8)
        .split(separator: "\n").first { $0.hasPrefix("libass ") })
    return String(line.split(separator: " ")[1])
  }
}
