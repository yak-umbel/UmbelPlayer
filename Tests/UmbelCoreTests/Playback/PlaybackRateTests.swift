import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

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

private func fixture(_ name: String) -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures").appendingPathComponent(name)
}

/// Playing faster or slower: the clock covers that many seconds of media a
/// second, the sound keeps up with it, and the rate stays through pauses and
/// seeks.
final class PlaybackRateTests: XCTestCase {
  private let host = FakeHostTime()
  private var output: VirtualAudioOutput!

  override func setUp() {
    super.setUp()
    // As a real output: a second queued at most. Holding more, it would take
    // everything read, and the cache — which buffering goes by — would look
    // empty.
    output = VirtualAudioOutput(hostTime: host)
  }

  private func session(sound: Bool = true) -> PlaybackSession {
    PlaybackSession(
      source: try! UmbelFileSource(url: fixture("seek_grid.mp4")),
      audioOutput: sound ? output : nil, hostTime: host)
  }

  private func started(_ session: PlaybackSession) async throws {
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<200 {
      if await session.phase == .playing { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("not playing within two seconds")
  }

  /// Host time goes by in small steps, the output playing along.
  private func run(_ session: PlaybackSession, seconds: Double) async throws {
    let steps = Int((seconds / 0.05).rounded())
    for _ in 0..<steps {
      host.advance(seconds: 0.05)
      await output.advance(bySeconds: 0.05)
      await session.refreshClock()
      try await Task.sleep(nanoseconds: 2_000_000)
    }
  }

  /// With sound, the clock follows the output: at twice the rate both cover
  /// two seconds in one. An output left at the normal rate would pull the
  /// clock back to one.
  func testTwiceTheRateMovesTwiceAsFar() async throws {
    let session = session()
    try await started(session)
    let before = await session.currentTime.seconds
    await session.setRate(2)
    try await run(session, seconds: 1)
    let after = await session.currentTime.seconds
    XCTAssertEqual(after - before, 2, accuracy: 0.1)
  }

  func testWithoutSoundTheHostClockRunsAtTheRate() async throws {
    let session = session(sound: false)
    try await started(session)
    let before = await session.currentTime.seconds
    await session.setRate(1.5)
    try await run(session, seconds: 1)
    let after = await session.currentTime.seconds
    XCTAssertEqual(after - before, 1.5, accuracy: 0.05)
  }

  /// A change while playing counts from then on: the position does not jump.
  func testChangingTheRateWhilePlayingKeepsThePosition() async throws {
    let session = session()
    try await started(session)
    try await run(session, seconds: 1)
    let before = await session.currentTime.seconds
    await session.setRate(2)
    let after = await session.currentTime.seconds
    XCTAssertEqual(after, before, accuracy: 0.02)
  }

  /// Pausing and playing again, and seeking, keep the rate chosen.
  func testTheRateHoldsAcrossPauseAndSeek() async throws {
    let session = session()
    try await started(session)
    await session.setRate(1.5)
    await session.pause()
    try await session.play()
    try await session.seek(to: CMTime(seconds: 10, preferredTimescale: 600))
    for _ in 0..<200 {
      if await session.phase == .playing { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let before = await session.currentTime.seconds
    try await run(session, seconds: 1)
    let after = await session.currentTime.seconds
    XCTAssertEqual(after - before, 1.5, accuracy: 0.1)
    let rate = await session.rate
    XCTAssertEqual(rate, 1.5)
  }

  func testARateSetBeforeLoadingApplies() async throws {
    let session = session()
    await session.setRate(2)
    try await started(session)
    let before = await session.currentTime.seconds
    try await run(session, seconds: 1)
    let after = await session.currentTime.seconds
    XCTAssertEqual(after - before, 2, accuracy: 0.1)
  }

  func testRatesAreHeldToTheSupportedRange() async {
    let session = session()
    await session.setRate(8)
    var rate = await session.rate
    XCTAssertEqual(rate, PlaybackSession.supportedRates.upperBound)
    await session.setRate(0.1)
    rate = await session.rate
    XCTAssertEqual(rate, PlaybackSession.supportedRates.lowerBound)
    await session.setRate(.nan)
    rate = await session.rate
    XCTAssertEqual(rate, PlaybackSession.supportedRates.lowerBound, "not a rate: left as it was")
  }

  /// The picture goes by the clock: at twice the rate, a second of host time
  /// in shows the frame two seconds in.
  func testThePictureFollowsTheRate() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")),
      videoRenderer: renderer, hostTime: host)
    await session.setRate(2)
    try await started(session)
    var shown: PresentedFrame?
    for _ in 0..<20 {
      host.advance(seconds: 0.05)
      try await Task.sleep(nanoseconds: 20_000_000)
      if let frame = try await session.renderVideoFrame() { shown = frame }
    }
    let time = try XCTUnwrap(shown).presentationTime.seconds
    XCTAssertEqual(time, 2, accuracy: 0.1)
  }
}
