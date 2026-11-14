import XCTest
@testable import UmbelCore

final class VideoSubmissionEpochTests: XCTestCase {
  func testACompletionFromBeforeFlushCannotSubmitPixels() {
    let epoch = VideoSubmissionEpoch()
    let old = epoch.value
    epoch.advance()
    var submitted = 0
    epoch.withCurrent(old) { submitted += 1 }
    XCTAssertEqual(submitted, 0)
    epoch.withCurrent(epoch.value) { submitted += 1 }
    XCTAssertEqual(submitted, 1)
  }
}
