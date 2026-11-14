import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSMBSource

final class UmbelSMBSourceNoticesTests: XCTestCase {
  func testTheLibraryItBringsIsNoticedWithItsPinnedVersionAndTheTermsOfTheLGPL() throws {
    let versions = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/BuildNetwork/VERSIONS"), encoding: .utf8)
    let line = try XCTUnwrap(versions.split(separator: "\n").first { $0.hasPrefix("libsmb2 ") })
    let notices = UmbelSMBSource.thirdPartyNotices
    XCTAssertEqual(notices.map(\.name), ["libsmb2"])
    XCTAssertEqual(notices[0].version, String(line.split(separator: " ")[1]))
    XCTAssertEqual(notices[0].license, "LGPL-2.1-or-later")
    XCTAssertTrue(notices[0].text.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
    XCTAssertTrue(notices[0].text.contains("https://github.com/sahlberg/libsmb2"), "where the source can be had")
    XCTAssertTrue(notices[0].text.contains("UmbelSMB2.framework"), "which library it is, that it may be replaced")
    XCTAssertGreaterThan(notices[0].text.count, 5_000)
  }
}
