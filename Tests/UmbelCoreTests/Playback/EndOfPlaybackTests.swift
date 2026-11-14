import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class ManualHost: HostTimeSource, @unchecked Sendable {
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

/// Playback has ended when the last of the content has been played, not
/// when the last of it has been read: the decoders and outputs still hold
/// seconds of it then. At the end the clock stops on the end and stays
/// there until a seek.
final class EndOfPlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// Steps time until the phase is `expected`, or fails after `limit` steps.
  /// Each step does what a host's display loop does too: asks for a frame.
  private func step(
    _ session: PlaybackSession, _ host: ManualHost, output: VirtualAudioOutput? = nil,
    until expected: UmbelPlaybackPhase, limit: Int = 200, by seconds: Double = 0.05
  ) async throws {
    for _ in 0..<limit {
      if await session.phase == expected { return }
      host.advance(seconds: seconds)
      await output?.advance(bySeconds: seconds)
      await session.refreshClock()
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let actual = await session.phase
    XCTFail("still \(actual), not \(expected)")
  }

  /// audio_only.m4a: two seconds of sound, read whole in a moment.
  func testSoundEndsWhenItHasPlayedNotWhenItHasBeenRead() async throws {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("audio_only.m4a")), audioOutput: output,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    // Everything is read and handed to the output within this.
    try await Task.sleep(nanoseconds: 300_000_000)
    let whileHeld = await session.phase
    XCTAssertEqual(whileHeld, .playing, "read to the end, but none of it played yet")

    try await step(session, host, output: output, until: .ended)
    let end = await session.currentTime
    let duration = await session.duration
    XCTAssertEqual(end.seconds, duration.seconds, accuracy: 0.05, "stopped on the end")

    host.advance(seconds: 3)
    await output.advance(bySeconds: 3)
    await session.refreshClock()
    let later = await session.currentTime
    XCTAssertEqual(later.seconds, end.seconds, accuracy: 0.001, "the clock stays on the end")
  }

  func testChangingDelayAfterAllAudioWasQueuedDoesNotChangeItsEnd() async throws {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("audio_only.m4a")), audioOutput: output,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    await session.setAudioDelay(0.5)
    try await session.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    let queued = await output.pendingSeconds
    XCTAssertGreaterThan(queued, 2.4)
    await session.setAudioDelay(0)
    for _ in 0..<21 {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let stillPlaying = await session.phase
    XCTAssertEqual(stillPlaying, .playing, "previously queued delayed samples still need to play")
    try await step(session, host, output: output, until: .ended)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 2, accuracy: 0.05)
  }

  /// Without sound the host clock runs the picture: pgs_subs.mkv is four
  /// seconds at 25 frames a second, its last frame shown from 3.96 s to 4.0 s.
  func testPictureEndsAfterItsLastFrameHasBeenShown() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let host = ManualHost()
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("pgs_subs.mkv")), videoRenderer: renderer,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    // Up to 3.9 s as the display loop would go, frame by frame.
    for _ in 0..<39 {
      host.advance(seconds: 0.1)
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let nearlyThere = await session.phase
    XCTAssertEqual(nearlyThere, .playing, "the last frame is still to come")

    try await step(session, host, until: .ended)
    let end = await session.currentTime
    XCTAssertEqual(end.seconds, 4.0, accuracy: 0.005, "the last frame counts its full 40 ms")

    host.advance(seconds: 5)
    let later = await session.currentTime
    XCTAssertEqual(later.seconds, end.seconds, accuracy: 0.001, "no running on past the end")
  }

  /// One chain has read to its end while the other still plays; a pause and
  /// a play then must not make playback forget the first has finished, or
  /// it would never be reported over. sync_check.mp4: six seconds, sound
  /// and picture; the sound is all handed on at once.
  func testPausingAfterOneChainFinishedStillEnds() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")), audioOutput: output,
      videoRenderer: renderer, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    await session.pause()
    try await session.play()
    try await step(session, host, output: output, until: .ended, limit: 400)
  }

  /// Play at the end does nothing until a seek moves away from it.
  func testPlayAtTheEndStaysAtTheEnd() async throws {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("audio_only.m4a")), audioOutput: output,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await step(session, host, output: output, until: .ended)
    let end = await session.currentTime

    try await session.play()
    host.advance(seconds: 2)
    await output.advance(bySeconds: 2)
    await session.refreshClock()
    let phase = await session.phase
    let time = await session.currentTime
    XCTAssertEqual(phase, .ended)
    XCTAssertEqual(time.seconds, end.seconds, accuracy: 0.001)
  }

  /// A seek moves away from the end, and playing runs again from there.
  func testASeekFromTheEndPlaysAgain() async throws {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("audio_only.m4a")), audioOutput: output,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await step(session, host, output: output, until: .ended)

    try await session.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
    try await step(session, host, output: output, until: .playing)
    let from = await session.currentTime
    for _ in 0..<5 {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
    let to = await session.currentTime
    XCTAssertGreaterThan(to.seconds, from.seconds + 0.3, "the clock runs again")
  }
}
