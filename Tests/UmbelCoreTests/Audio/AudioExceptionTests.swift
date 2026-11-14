import AVFoundation
import XCTest
@testable import UmbelCore

/// AVFAudio reports some runtime faults as Objective-C exceptions, which Swift
/// cannot catch: uncaught, they end the process. "Player did not see an IO
/// cycle" — raised when an output device stops delivering — took down a whole
/// test run. The output turns them into errors instead.
final class AudioExceptionTests: XCTestCase {
  /// A player node attached to no engine refuses to play with an exception:
  /// a fault that can be produced on demand, standing in for the device
  /// failures that cannot.
  func testAnExceptionBecomesAnError() {
    let orphan = AVAudioPlayerNode()
    XCTAssertThrowsError(try EngineAudioOutput.guarded { orphan.play() }) { error in
      guard case UmbelError.audioOutputUnavailable(let reason) = error else {
        return XCTFail("\(error)")
      }
      XCTAssertFalse(reason.isEmpty, "the exception's reason is kept")
    }
  }

  func testNothingRaisedMeansNoError() throws {
    var ran = false
    try EngineAudioOutput.guarded { ran = true }
    XCTAssertTrue(ran)
  }
}
