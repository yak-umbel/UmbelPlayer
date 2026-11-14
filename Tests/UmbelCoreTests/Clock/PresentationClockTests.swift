import CoreMedia
import XCTest
@testable import UmbelCore

/// A host clock under control: tests run ten minutes in milliseconds with it.
private final class FakeHostTime: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    defer { lock.unlock() }
    seconds += delta
  }
}

/// What a follower heard, in order: media time, host time, rate.
private final class RecordingFollower: ClockFollower, @unchecked Sendable {
  private let lock = NSLock()
  private var heard: [(media: Double, host: Double, rate: Double)] = []

  var changes: [(media: Double, host: Double, rate: Double)] {
    lock.lock()
    defer { lock.unlock() }
    return heard
  }

  func clockDidChange(anchor: RenderAnchor, rate: Double) {
    lock.lock()
    heard.append((anchor.mediaTime.seconds, anchor.hostTime.seconds, rate))
    lock.unlock()
  }
}

final class PresentationClockTests: XCTestCase {
  /// Every change of anchor or rate reaches the follower as it happens:
  /// playing, sound's anchors, seeking, a change of rate, stopping at the
  /// end. What it is given places the clock exactly.
  func testFollowersHearEveryChange() async {
    let host = FakeHostTime()
    let follower = RecordingFollower()
    let clock = PresentationClock(hostTime: host, follower: follower)
    await clock.setRate(1)
    host.advance(seconds: 2)
    await clock.adopt(RenderAnchor(
      mediaTime: CMTime(seconds: 2.5, preferredTimescale: 600), hostTime: host.now))
    await clock.reset(to: CMTime(seconds: 10, preferredTimescale: 600))
    await clock.setRate(2)
    await clock.stop(at: CMTime(seconds: 30, preferredTimescale: 600))
    let changes = follower.changes
    XCTAssertEqual(changes.map(\.media), [0, 2.5, 10, 10, 30])
    XCTAssertEqual(changes.map(\.host), [0, 2, 2, 2, 2])
    XCTAssertEqual(changes.map(\.rate), [1, 1, 1, 2, 2])
  }

  func testStartsAtZeroAndPaused() async {
    let clock = PresentationClock(hostTime: FakeHostTime())
    let rate = await clock.rate
    let time = await clock.now()
    XCTAssertEqual(rate, 0)
    XCTAssertEqual(time, .zero)
  }

  func testPausedClockDoesNotAdvance() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    host.advance(seconds: 5)
    let time = await clock.now()
    XCTAssertEqual(time.seconds, 0, accuracy: 0.0001, "at rate 0, host time passing does not move the presentation time")
  }

  func testRunningClockFollowsHostWhenAuthorityIsHost() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(1)
    host.advance(seconds: 3)
    let time = await clock.now()
    XCTAssertEqual(time.seconds, 3, accuracy: 0.0001)
  }

  func testPauseDoesNotCountPausedDuration() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(1)
    host.advance(seconds: 2)
    await clock.setRate(0)          // pause
    host.advance(seconds: 100)      // the host moves on a long way while paused
    await clock.setRate(1)          // resume
    host.advance(seconds: 1)
    let time = await clock.now()
    XCTAssertEqual(time.seconds, 3, accuracy: 0.0001, "the 100 s paused do not count")
  }

  func testResetJumpsImmediately() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(1)
    host.advance(seconds: 10)
    await clock.reset(to: CMTime(seconds: 120, preferredTimescale: 600))
    let immediately = await clock.now()
    XCTAssertEqual(immediately.seconds, 120, accuracy: 0.0001, "after a seek it jumps rather than creeping")
    host.advance(seconds: 1)
    let later = await clock.now()
    XCTAssertEqual(later.seconds, 121, accuracy: 0.0001)
  }

  /// Stopped on the end of playback, the clock stays there: an output
  /// reporting where it got to does not move it, until a seek does.
  func testAClockStoppedAtTheEndStaysThere() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.stop(at: CMTime(seconds: 16, preferredTimescale: 600))
    await clock.adopt(RenderAnchor(
      mediaTime: CMTime(seconds: 12, preferredTimescale: 600), hostTime: host.now))
    let held = await clock.now()
    XCTAssertEqual(held.seconds, 16, accuracy: 1e-6)

    await clock.reset(to: CMTime(seconds: 3, preferredTimescale: 600))
    await clock.adopt(RenderAnchor(
      mediaTime: CMTime(seconds: 4, preferredTimescale: 600), hostTime: host.now))
    let moved = await clock.now()
    XCTAssertEqual(moved.seconds, 4, accuracy: 1e-6)
  }

  /// At twice the rate the clock covers two seconds in one.
  func testTheClockRunsAtTheRate() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(2)
    host.advance(seconds: 1)
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 2, accuracy: 1e-6)
  }

  /// A change of rate while running takes effect from then on: what went
  /// before counts at the old rate, and the position does not jump.
  func testChangingTheRateWhileRunningDoesNotJump() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(1)
    host.advance(seconds: 3)
    await clock.setRate(1.5)
    let at = await clock.now()
    XCTAssertEqual(at.seconds, 3, accuracy: 1e-6)
    host.advance(seconds: 2)
    let later = await clock.now()
    XCTAssertEqual(later.seconds, 6, accuracy: 1e-6)
  }

  func testAuthorityDefaultsToHost() async {
    let clock = PresentationClock(hostTime: FakeHostTime())
    let authority = await clock.authority
    XCTAssertEqual(authority, .host)
  }

  func testAdoptingAnchorMovesClock() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setAuthority(.audio)
    await clock.setRate(1)
    host.advance(seconds: 1)
    await clock.adopt(
      RenderAnchor(mediaTime: CMTime(seconds: 5, preferredTimescale: 600), hostTime: host.now)
    )
    let time = await clock.now()
    XCTAssertEqual(time.seconds, 5, accuracy: 0.0001, "the anchor sets the position directly")
  }

  /// The one that matters most.
  ///
  /// The trap: driven by one virtual time, the virtual output and the fake
  /// host clock can never drift, and the test proves only itself, catching
  /// no bug. Real-world imperfection is brought in on purpose — a real
  /// device's sample rate is never exactly 48000, and the audio clock slowly
  /// parts from the host clock.
  func testClockFollowsAudioNotHostOverTenMinutes() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setAuthority(.audio)
    await clock.setRate(1)

    let audioRateFactor = 0.999   // the device runs 0.1% slow
    let stepSeconds = 0.1
    let steps = Int(600 / stepSeconds)   // 10 minutes
    var audioPosition = 0.0

    for _ in 0..<steps {
      host.advance(seconds: stepSeconds)
      audioPosition += stepSeconds * audioRateFactor
      await clock.adopt(
        RenderAnchor(
          mediaTime: CMTime(seconds: audioPosition, preferredTimescale: 1_000_000),
          hostTime: host.now
        )
      )
    }

    let time = await clock.now()
    XCTAssertEqual(time.seconds, 600 * audioRateFactor, accuracy: 0.01,
                   "the clock follows the audio position (about 599.4 s), not host time (600 s)")
    XCTAssertLessThan(time.seconds, 599.9,
                      "near 600, host time has taken over — audio is no longer the authority")
  }

  func testHostAuthorityTracksHostExactlyOverTenMinutes() async {
    let host = FakeHostTime()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(1)   // authority stays host; no anchors fed
    for _ in 0..<6000 { host.advance(seconds: 0.1) }
    let time = await clock.now()
    XCTAssertEqual(time.seconds, 600, accuracy: 0.0001, "without sound it follows the host exactly")
  }
}
