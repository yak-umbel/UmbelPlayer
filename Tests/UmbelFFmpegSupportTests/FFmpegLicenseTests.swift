import Foundation
import XCTest
@testable import UmbelFFmpegSupport

/// The license guard at run time.
///
/// Tools/verify_ffmpeg_license.sh checks the build configuration; this test
/// checks the license the binary reports itself. The two are independent,
/// and either failing means no release.
///
/// This file deliberately **does not reuse** UmbelFFmpegSupport's own check
/// but works the expected value out again with range(of:); reusing the
/// implementation would make the assertion prove only itself. range(of:)
/// rather than contains(_:), which needs macOS 13 / iOS 16, above the
/// package's platform floor.
final class FFmpegLicenseTests: XCTestCase {
  private func containsLGPL(_ s: String) -> Bool {
    s.range(of: "LGPL") != nil
  }

  private func containsNonfree(_ s: String) -> Bool {
    s.range(of: "nonfree", options: .caseInsensitive) != nil
  }

  func testFFmpegIsLinked() {
    XCTAssertNotNil(
      UmbelFFmpegSupport.ffmpegVersion,
      "FFmpeg is not linked in. Run Tools/BuildFFmpeg/build.sh first"
    )
  }

  func testFFmpegReportsLGPLLicense() throws {
    let license = try XCTUnwrap(UmbelFFmpegSupport.ffmpegLicense)
    XCTAssertTrue(
      containsLGPL(license),
      "FFmpeg reports its license as \"\(license)\"; LGPL is required"
    )
    XCTAssertFalse(
      containsNonfree(license),
      "FFmpeg reports itself nonfree; this build cannot be distributed: \(license)"
    )
  }

  func testIsLGPLBuildMatchesReportedLicense() throws {
    let license = try XCTUnwrap(UmbelFFmpegSupport.ffmpegLicense)
    XCTAssertEqual(
      UmbelFFmpegSupport.isLGPLBuild,
      containsLGPL(license) && !containsNonfree(license)
    )
  }
}
