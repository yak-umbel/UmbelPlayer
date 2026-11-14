import XCTest
@testable import UmbelCore

/// Whose problem a player that does not play is: given everything it asked
/// for, the route's; waiting on reading, buffering.
final class StallWatchTests: XCTestCase {
  func testGivenAllItAskedForAndStillNotPlayingForFiveSeconds() {
    var watch = StallWatch()
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 10))
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 14.9))
    XCTAssertTrue(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 15))
  }

  func testWaitingOnReadingIsBufferingAndStartsTheCountAgain() {
    var watch = StallWatch()
    _ = watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 0)
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: true, at: 4))
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: true, at: 60))
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 61))
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 65.9))
    XCTAssertTrue(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 66))
  }

  /// Reading stopped at the packet budget: stuck only once it has stayed
  /// so for the patience given, without a look finding it moving between.
  func testAnotherStandstillWatchedWithAPatienceOfItsOwn() {
    var watch = StallWatch(patience: 0.3)
    XCTAssertFalse(watch.look(stuck: true, at: 10))
    XCTAssertFalse(watch.look(stuck: true, at: 10.2))
    XCTAssertFalse(watch.look(stuck: false, at: 10.25), "moving again starts the count again")
    XCTAssertFalse(watch.look(stuck: true, at: 10.3))
    XCTAssertFalse(watch.look(stuck: true, at: 10.5))
    XCTAssertTrue(watch.look(stuck: true, at: 10.7))
  }

  func testPlayingOrPausedStartsTheCountAgain() {
    var watch = StallWatch()
    _ = watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 0)
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: true, waitingOnReading: false, at: 4))
    _ = watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 5)
    XCTAssertFalse(watch.look(shouldPlay: false, isPlaying: false, waitingOnReading: false, at: 9))
    XCTAssertFalse(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 13))
    XCTAssertTrue(watch.look(shouldPlay: true, isPlaying: false, waitingOnReading: false, at: 18))
  }
}
