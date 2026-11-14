import CoreMedia
import XCTest
@testable import UmbelCore

/// The real renderer and synchronizer, silent. Without an audio device the
/// timeline never starts: skipped with the reason, nothing passes silently.
final class SampleBufferAudioDeviceTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// A session on sync_check.mp4 (6 s, AAC) with a silent real output,
  /// playing: or skipped where the timeline does not start within 3 s.
  private func playing() async throws -> PlaybackSession {
    let output = SampleBufferAudioOutput(timeline: SynchronizerTimeline()) {
      SystemAudioRenderer(volume: 0, onDiscarded: $0)
    }
    let session = PlaybackSession(source: try UmbelFileSource(url: fixture("sync_check.mp4")), audioOutput: output)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<300 where await session.currentTime.seconds <= 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard await session.currentTime.seconds > 0 else { throw XCTSkip("no audio output device here") }
    return session
  }

  private func advance(of session: PlaybackSession, over seconds: Double) async throws -> Double {
    // How far it went for each `seconds` of real time: a sleep returns late on a busy machine.
    let before = await session.currentTime.seconds
    let started = ContinuousClock.now
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let moved = await session.currentTime.seconds - before
    let elapsed = (ContinuousClock.now - started).inSeconds
    return moved * seconds / elapsed
  }

  /// From standing, the timeline starts once the sound really comes out —
  /// the device's latency later, a Bluetooth headset's most of all. Started
  /// at once, it ran ahead, and the first words of a film went unheard
  /// while the lips moved.
  func testAColdStartWaitsForTheSound() async throws {
    try XCTSkipIf(
      HostEnvironment.isVirtualMachine,
      "a virtual machine's sound device has no output latency for the timeline to wait for")
    let timeline = SynchronizerTimeline()
    let renderer = SystemAudioRenderer(volume: 0, onDiscarded: {})
    try timeline.add(renderer.queued)
    for index in 0..<30 {
      renderer.enqueue(try PCMSampleBuffer.make(AudioFrame(
        presentationTime: CMTime(value: CMTimeValue(index * 4800), timescale: 48_000), sampleRate: 48_000,
        channelCount: 2, frameCount: 4800, samples: [Float](repeating: 0, count: 9600))))
    }
    timeline.set(rate: 1, time: .zero)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let time = timeline.time.seconds
    guard time > 0 else { throw XCTSkip("no audio output device here") }
    XCTAssertLessThan(time, 0.95, "the timeline waited for the sound to come out")
  }

  func testTheTimelineRunsWithTheSound() async throws {
    let session = try await playing()
    let moved = try await advance(of: session, over: 1)
    XCTAssertEqual(moved, 1, accuracy: 0.1)
  }

  func testTwiceAsFast() async throws {
    let session = try await playing()
    await session.setRate(2)
    try await Task.sleep(nanoseconds: 200_000_000)
    let moved = try await advance(of: session, over: 1)
    XCTAssertEqual(moved, 2, accuracy: 0.2)
  }

  func testASeekPlaysOnFromTheTarget() async throws {
    let session = try await playing()
    try await session.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
    for _ in 0..<300 where await session.currentTime.seconds < 3.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let now = await session.currentTime.seconds
    XCTAssertEqual(now, 3.1, accuracy: 0.2)
  }
}
