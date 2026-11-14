import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// Counts what a follower hears.
private final class CountingFollower: ClockFollower, @unchecked Sendable {
  private let lock = NSLock()
  private var heard = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return heard
  }

  func clockDidChange(anchor: RenderAnchor, rate: Double) {
    lock.lock()
    heard += 1
    lock.unlock()
  }
}

/// The clock on the system's timeline: it reads the timeline's time rather
/// than working it out, and sets every change of rate or position on it.
final class SystemTimelineClockTests: XCTestCase {
  private let host = TimelineHostTime()
  private lazy var timeline = TimelineDouble(host: host)
  private lazy var clock = PresentationClock(hostTime: host, follower: nil, timeline: timeline)

  private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

  func testNowIsTheTimelinesTime() async {
    timeline.set(rate: 1, time: seconds(5))
    host.advance(seconds: 2)
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 7, accuracy: 1e-6)
  }

  /// Playing, pausing, seeking and a change of rate: each is set on the
  /// timeline where the clock stood, at the host time it happened.
  func testChangesAreSetOnTheTimeline() async {
    await clock.setRate(1)
    host.advance(seconds: 2)
    await clock.setRate(0)
    await clock.reset(to: seconds(10))
    await clock.setRate(2)
    host.advance(seconds: 1)
    XCTAssertEqual(timeline.sets, [
      .init(rate: 0, time: 10, host: 2)])
    XCTAssertEqual(timeline.rateOnlySets, [1, 0, 2])
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 12, accuracy: 1e-6)
  }

  /// A speed change preserves the timeline's current position without
  /// issuing another position change.
  func testRateChangeUsesRateOnlyControl() async {
    await clock.setRate(1)
    host.advance(seconds: 2)
    await clock.setRate(1.25)
    XCTAssertEqual(timeline.rateOnlySets, [1, 1.25])
    XCTAssertTrue(timeline.sets.isEmpty)
    host.advance(seconds: 1)
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 3.25, accuracy: 1e-6)
  }

  func testSpeedChangesOnTheRealTimelineDoNotJumpItsTime() async throws {
    let real = SynchronizerTimeline()
    let switchable = SwitchableTimeline(base: real)
    let clock = PresentationClock(hostTime: SystemHostTimeSource(), follower: nil, timeline: switchable)
    await clock.reset(to: seconds(5))
    await clock.setRate(1)
    try await Task.sleep(nanoseconds: 200_000_000)
    for rate in [1.25, 2.0, 1.0] {
      let before = real.time.seconds
      let hostBefore = CMClockGetTime(CMClockGetHostTimeClock()).seconds
      await clock.setRate(rate)
      try await Task.sleep(nanoseconds: 150_000_000)
      let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - hostBefore
      XCTAssertEqual(CMTimebaseGetEffectiveRate(real.synchronizer.timebase), rate)
      XCTAssertEqual(real.time.seconds - before, elapsed * rate, accuracy: 0.03,
                     "changing speed must preserve the timebase's position")
    }
    await clock.setRate(0)
  }

  /// At the end the timeline stops there, and nothing pulls it back.
  func testTheEndStopsTheTimeline() async {
    await clock.setRate(1)
    await clock.stop(at: seconds(30))
    XCTAssertEqual(timeline.sets.last, .init(rate: 0, time: 30, host: 0))
    await clock.adopt(RenderAnchor(mediaTime: seconds(12), hostTime: host.now))
    host.advance(seconds: 5)
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 30, accuracy: 1e-6)
  }

  /// An output's anchors have no say: the timeline is the time, and no
  /// follower hears of them.
  func testAnchorsAreNotAdopted() async {
    let follower = CountingFollower()
    let clock = PresentationClock(hostTime: host, follower: follower, timeline: timeline)
    timeline.set(rate: 0, time: seconds(4))
    await clock.adopt(RenderAnchor(mediaTime: seconds(99), hostTime: host.now))
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 4, accuracy: 1e-6)
    XCTAssertEqual(follower.count, 0)
  }

  /// Sound switched off leaves the time with the system, not the host.
  func testTheAuthorityIsTheSystemsAndStays() async {
    let before = await clock.authority
    XCTAssertEqual(before, .system)
    await clock.setAuthority(.host)
    let after = await clock.authority
    XCTAssertEqual(after, .system)
  }

  /// The real synchronizer runs from where it is set.
  func testASynchronizerRunsFromWhereItIsSet() async throws {
    let real = SynchronizerTimeline()
    real.set(rate: 1, time: seconds(5))
    let elapsed = try await sleepMeasured(0.2)
    XCTAssertEqual(real.time.seconds, 5 + elapsed, accuracy: 0.1)
  }

  /// A layer with its own timebase is one the system will not take: an
  /// error, not the end of the process.
  @MainActor
  func testALayerWithATimebaseIsRefusedNotFatal() throws {
    let layer = AVSampleBufferDisplayLayer()
    var own: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &own)
    layer.controlTimebase = own
    XCTAssertThrowsError(try SynchronizerTimeline().add(QueuedRenderer(renderer: layer)))
  }
  func testDiagnosticsCompareTheReadTimeWithTheRenderingTimebase() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let real = SynchronizerTimeline()
    await (real as? any PlaybackDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics)
    real.set(rate: 1.25, time: seconds(5))
    try await Task.sleep(nanoseconds: 200_000_000)
    _ = real.time
    let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.name == "system_clock_read" })
    XCTAssertEqual(try XCTUnwrap(event.values["readTime"]), 5.25, accuracy: 0.15)
    XCTAssertEqual(try XCTUnwrap(event.values["timebaseTime"]), 5.25, accuracy: 0.15)
    XCTAssertEqual(event.values["effectiveRate"], 1.25)
    XCTAssertEqual(event.values["requestedRate"], 1.25)
  }

  func testARateOnlyControlKeepsAnAcceptedSeekUntilItsTimebaseUpdates() async throws {
    for previousRate in [0.0, 1.0] {
      let timeline = SynchronizerTimeline()
      timeline.set(rate: previousRate, time: .zero)
      try await Task.sleep(nanoseconds: 100_000_000)
      for target in [10.0, 2.0, 20.0, 0.0] {
        timeline.set(rate: previousRate, time: CMTime(seconds: target, preferredTimescale: 600))
        timeline.setRate(2)
        // Against the time that really passed: a sleep returns late on a busy machine.
        let started = ContinuousClock.now
        try await Task.sleep(nanoseconds: 100_000_000)
        let elapsed = (ContinuousClock.now - started).inSeconds
        XCTAssertEqual(timeline.time.seconds, target + 2 * elapsed, accuracy: 0.1,
                       "changing speed must preserve a seek accepted immediately before it")
      }
      timeline.setRate(0)
    }
  }

}
