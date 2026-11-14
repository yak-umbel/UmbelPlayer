import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSFTPSource

final class UmbelSFTPSourceNoticesTests: XCTestCase {
  func testTheLibrariesItBringsAreNoticedWithTheirPinnedVersionsAndFullTexts() throws {
    let versions = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/BuildNetwork/VERSIONS"), encoding: .utf8)
    func pinned(_ name: String) throws -> String {
      let line = try XCTUnwrap(versions.split(separator: "\n").first { $0.hasPrefix(name + " ") })
      return String(line.split(separator: " ")[1])
    }
    let notices = UmbelSFTPSource.thirdPartyNotices
    XCTAssertEqual(notices.map(\.name), ["libssh2", "OpenSSL"])
    XCTAssertEqual(notices[0].version, try pinned("libssh2"))
    XCTAssertEqual(notices[1].version, try pinned("openssl"))
    XCTAssertEqual(notices[0].license, "BSD-3-Clause")
    XCTAssertEqual(notices[1].license, "Apache-2.0")
    XCTAssertTrue(notices[0].text.contains("Redistribution and use in source and binary forms"))
    XCTAssertTrue(notices[1].text.contains("Apache License"))
    for notice in notices { XCTAssertGreaterThan(notice.text.count, 500, notice.name) }
  }
}
