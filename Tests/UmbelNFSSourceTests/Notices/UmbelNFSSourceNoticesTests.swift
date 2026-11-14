import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelNFSSource

final class UmbelNFSSourceNoticesTests: XCTestCase {
  func testTheLibraryItBringsIsNoticedWithItsPinnedVersionAndTheTermsOfTheLGPLAndTheBSDOfItsProtocolCode() throws {
    let versions = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/BuildNetwork/VERSIONS"), encoding: .utf8)
    let line = try XCTUnwrap(versions.split(separator: "\n").first { $0.hasPrefix("libnfs ") })
    let notices = UmbelNFSSource.thirdPartyNotices
    XCTAssertEqual(notices.map(\.name), ["libnfs"])
    XCTAssertEqual(notices[0].version, String(line.split(separator: " ")[1]))
    XCTAssertEqual(notices[0].license, "LGPL-2.1-or-later")
    XCTAssertTrue(notices[0].text.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
    XCTAssertTrue(notices[0].text.contains("Simplified BSD License"), "the protocol code's terms")
    XCTAssertTrue(notices[0].text.contains("Redistribution and use in source and binary forms"))
    XCTAssertTrue(notices[0].text.contains("https://github.com/sahlberg/libnfs"), "where the source can be had")
    XCTAssertTrue(notices[0].text.contains("UmbelNFS.framework"), "which library it is, that it may be replaced")
    XCTAssertGreaterThan(notices[0].text.count, 5_000)
  }
}
