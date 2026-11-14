import XCTest
import UmbelCore

/// What a host logs to see which libraries it runs on: another copy of
/// FFmpeg or libass answering here would show as another version.
final class UmbelVersionTests: XCTestCase {
  func testFFmpegSaysItsVersionAndLicense() throws {
    let version = try XCTUnwrap(Umbel.ffmpegVersion)
    XCTAssertTrue(version.hasPrefix("n9."), version)
    let license = try XCTUnwrap(Umbel.ffmpegLicense)
    XCTAssertEqual(license, "LGPL version 2.1 or later")
  }

  func testLibassSaysItsVersion() {
    XCTAssertTrue(Umbel.libassVersion.hasPrefix("0."), Umbel.libassVersion)
  }
}
