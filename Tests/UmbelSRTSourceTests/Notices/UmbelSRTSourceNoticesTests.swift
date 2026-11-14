import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSRTSource

final class UmbelSRTSourceNoticesTests: XCTestCase {
  func testTheLibrariesItBringsAreNoticedWithTheirPinnedVersionsAndFullTexts() throws {
    let versions = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/BuildNetwork/VERSIONS"), encoding: .utf8)
    func pinned(_ name: String) throws -> String {
      let line = try XCTUnwrap(versions.split(separator: "\n").first { $0.hasPrefix(name + " ") })
      return String(line.split(separator: " ")[1])
    }
    let notices = UmbelSRTSource.thirdPartyNotices
    XCTAssertEqual(notices.map(\.name), ["SRT", "OpenSSL"])
    XCTAssertEqual(notices[0].version, try pinned("srt"))
    XCTAssertEqual(notices[1].version, try pinned("openssl"))
    XCTAssertEqual(notices[0].license, "MPL-2.0")
    XCTAssertEqual(notices[1].license, "Apache-2.0")
    XCTAssertTrue(notices[0].text.contains("Mozilla Public License Version 2.0"))
    XCTAssertTrue(notices[0].text.contains("https://github.com/Haivision/srt"), "where the source can be had, as the MPL asks")
    XCTAssertTrue(notices[1].text.contains("Apache License"))
    for notice in notices { XCTAssertGreaterThan(notice.text.count, 500, notice.name) }
  }
}
