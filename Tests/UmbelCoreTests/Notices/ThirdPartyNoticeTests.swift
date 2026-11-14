import Foundation
import XCTest
import UmbelCore

final class ThirdPartyNoticeTests: XCTestCase {
  private func projectFile(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(path)
  }

  private func pinnedVersion(_ name: String) throws -> String {
    if name == "dav1d" {
      let pin = try String(contentsOf: projectFile("Tools/BuildFFmpeg/DAV1D_VERSION"), encoding: .utf8)
      return String(try XCTUnwrap(pin.split(whereSeparator: \.isWhitespace).first))
    }
    if name == "FFmpeg" {
      return try String(contentsOf: projectFile("Tools/BuildFFmpeg/FFMPEG_VERSION"),
                        encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let versions = try String(contentsOf: projectFile("Tools/BuildLibass/VERSIONS"), encoding: .utf8)
    let line = try XCTUnwrap(versions.split(separator: "\n").first {
      $0.hasPrefix(name.lowercased() + " ")
    })
    return String(line.split(separator: " ")[1])
  }

  func testNoticesContainPinnedVersionsAndFullTexts() throws {
    let notices = Umbel.thirdPartyNotices
    XCTAssertEqual(notices.map(\.name), ["FFmpeg", "libass", "FriBidi", "FreeType", "HarfBuzz", "dav1d"])
    for notice in notices {
      XCTAssertEqual(notice.version, try pinnedVersion(notice.name))
      XCTAssertGreaterThan(notice.text.count, 500, notice.name)
    }
    XCTAssertEqual(notices[0].version, Umbel.ffmpegVersion)
    XCTAssertEqual(notices[1].version, Umbel.libassVersion)
    XCTAssertTrue(notices[0].text.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
    XCTAssertTrue(notices[3].text.contains("The FreeType Project LICENSE"))
    XCTAssertTrue(notices[3].text.contains("Portions of this software are copyright"))
    let dav1d = try XCTUnwrap(notices.first { $0.name == "dav1d" })
    XCTAssertEqual(dav1d.license, "BSD-2-Clause")
    XCTAssertTrue(dav1d.text.contains("VideoLAN and dav1d authors"))
    XCTAssertTrue(dav1d.text.contains("Redistributions in binary form"))
  }
}
