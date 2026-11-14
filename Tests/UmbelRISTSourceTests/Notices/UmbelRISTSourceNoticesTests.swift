import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelRISTSource

final class UmbelRISTSourceNoticesTests: XCTestCase {
  func testTheLibrariesItBringsAreNoticedWithTheirFullTexts() throws {
    let versions = try String(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/BuildNetwork/VERSIONS"), encoding: .utf8)
    let line = try XCTUnwrap(versions.split(separator: "\n").first { $0.hasPrefix("librist ") })
    let pinned = String(line.split(separator: " ")[1])
    let notices = UmbelRISTSource.thirdPartyNotices
    XCTAssertEqual(notices.map(\.name), ["librist", "Mbed TLS", "lz4", "cJSON"])
    XCTAssertEqual(notices[0].version, pinned, "the notice names the version that is built")
    XCTAssertEqual(notices.map(\.license), ["BSD-2-Clause", "Apache-2.0", "BSD-2-Clause", "MIT"])
    XCTAssertTrue(notices[0].text.contains("VideoLAN and librist authors"))
    XCTAssertTrue(notices[0].text.contains("Redistribution and use in source and binary forms"))
    XCTAssertTrue(notices[1].text.contains("Apache License"))
    XCTAssertTrue(notices[1].text.contains("used here under Apache-2.0"), "which of the two licenses is the one used")
    XCTAssertTrue(notices[2].text.contains("Yann Collet"))
    XCTAssertTrue(notices[3].text.contains("Dave Gamble"))
    XCTAssertTrue(notices[3].text.contains("Permission is hereby granted"))
    for notice in notices { XCTAssertGreaterThan(notice.text.count, 500, notice.name) }
  }
}
