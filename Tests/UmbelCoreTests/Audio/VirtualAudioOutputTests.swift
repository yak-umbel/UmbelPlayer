import CoreMedia
import XCTest
@testable import UmbelCore

/// Only to see whether a task really returned.
private actor Flag {
  private var raised = false
  var isRaised: Bool { raised }
  func raise() { raised = true }
}

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

private func makeFrame(startSeconds: Double, durationSeconds: Double) -> AudioFrame {
  let sampleRate = 48_000.0
  let frameCount = Int(durationSeconds * sampleRate)
  return AudioFrame(
    presentationTime: CMTime(seconds: startSeconds, preferredTimescale: 48_000),
    sampleRate: sampleRate,
    channelCount: 2,
    frameCount: frameCount,
    samples: [Float](repeating: 0, count: frameCount * 2)
  )
}

final class VirtualAudioOutputTests: XCTestCase {
  func testAnchorIsNilBeforeAnythingIsRendered() async throws {
    let output = VirtualAudioOutput(hostTime: FakeHostTime())
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    let anchor = await output.currentAnchor
    XCTAssertNil(anchor)
  }

  /// At twice the rate a second of host time plays two of sound.
  func testTheVirtualOutputPlaysAtTheRate() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 10)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeFrame(startSeconds: 5, durationSeconds: 4))
    await output.setRate(2)
    try await output.start()
    host.advance(seconds: 1)
    await output.advance(bySeconds: 1)
    let anchor = await output.currentAnchor
    XCTAssertEqual(anchor?.mediaTime.seconds ?? -1, 7, accuracy: 1e-6)
    let pending = await output.pendingSeconds
    XCTAssertEqual(pending, 2, accuracy: 1e-6)
  }

  func testAdvanceConsumesEnqueuedAudio() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 1))
    try await output.start()

    host.advance(seconds: 0.5)
    await output.advance(bySeconds: 0.5)

    let read = await output.currentAnchor
    let anchor = try XCTUnwrap(read)
    XCTAssertEqual(anchor.mediaTime.seconds, 0.5, accuracy: 0.001)
    XCTAssertEqual(anchor.hostTime.seconds, 0.5, accuracy: 0.001)
  }

  func testRateFactorMakesAudioLagHost() async throws {
    let host = FakeHostTime()
    // A device running slow.
    let output = VirtualAudioOutput(hostTime: host, rateFactor: 0.999, maxPendingSeconds: 100)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 10))
    try await output.start()

    host.advance(seconds: 10)
    await output.advance(bySeconds: 10)

    let read = await output.currentAnchor
    let anchor = try XCTUnwrap(read)
    XCTAssertEqual(anchor.mediaTime.seconds, 9.99, accuracy: 0.01,
                   "a slow device plays only 9.99 s of content in 10 s of host time")
  }

  func testPausedOutputDoesNotConsume() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 100)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 5))
    try await output.start()
    host.advance(seconds: 1)
    await output.advance(bySeconds: 1)
    await output.pause()
    host.advance(seconds: 10)
    await output.advance(bySeconds: 10)

    let read = await output.currentAnchor
    let anchor = try XCTUnwrap(read)
    XCTAssertEqual(anchor.mediaTime.seconds, 1, accuracy: 0.001, "nothing more is played once paused")
  }

  func testCannotConsumeBeyondEnqueuedAudio() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 1))
    try await output.start()
    host.advance(seconds: 5)
    await output.advance(bySeconds: 5)

    let read = await output.currentAnchor
    let anchor = try XCTUnwrap(read)
    XCTAssertEqual(anchor.mediaTime.seconds, 1, accuracy: 0.001,
                   "without more audio it cannot move on from nothing — the clock would run ahead of the content")
  }

  func testEnqueueBlocksWhenPendingIsFull() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.5)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.start()
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 0.5))

    // Already full with 0.5 s; the next enqueue has to wait for playing.
    let producer = Task {
      try? await output.enqueue(makeFrame(startSeconds: 0.5, durationSeconds: 0.5))
    }
    host.advance(seconds: 0.3)
    await output.advance(bySeconds: 0.3)
    await producer.value

    let read = await output.currentAnchor
    let anchor = try XCTUnwrap(read)
    XCTAssertEqual(anchor.mediaTime.seconds, 0.3, accuracy: 0.001)
  }

  func testStopResetsPosition() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 1))
    try await output.start()
    host.advance(seconds: 0.5)
    await output.advance(bySeconds: 0.5)
    await output.stop()
    let anchor = await output.currentAnchor
    XCTAssertNil(anchor)
  }


  /// Backpressure still holds while paused.
  ///
  /// The protocol says a full queue waits: the backpressure. The first
  /// version's wait depended on `isRunning`, explained as "no blocking before
  /// playing starts, to fill up first" — but the condition held just the same
  /// when paused after start, and feeding while paused decoded the whole
  /// file into memory. The double keeps its own contract, or the pipeline's
  /// pausing would rest on nothing.
  func testPausedOutputStillAppliesBackpressure() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.5)
    try await output.start()
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 0.5))
    await output.pause()

    let returned = Flag()
    let blocked = Task {
      try? await output.enqueue(makeFrame(startSeconds: 0.5, durationSeconds: 0.5))
      await returned.raise()
    }
    try await Task.sleep(nanoseconds: 100_000_000)

    let finished = await returned.isRaised
    XCTAssertFalse(finished, "full, it waits rather than returning")

    await output.stop()   // stop lets the waiter go, so the task can finish
    _ = await blocked.value
  }

  /// What backpressure is seen to do: the backlog stays within the limit.
  func testPausedOutputDoesNotAccumulateBeyondLimit() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.5)
    try await output.start()
    try await output.enqueue(makeFrame(startSeconds: 0, durationSeconds: 0.5))
    await output.pause()

    let extra = Task {
      try? await output.enqueue(makeFrame(startSeconds: 0.5, durationSeconds: 0.5))
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    let pending = await output.pendingSeconds
    XCTAssertEqual(pending, 0.5, accuracy: 0.001, "paused, the backlog stays within its limit")

    await output.stop()
    _ = await extra.value
  }
}

final class UmbelErrorAudioTests: XCTestCase {
  func testAudioOutputUnavailableIsRetryable() {
    XCTAssertTrue(UmbelError.audioOutputUnavailable(reason: "no output device").isRetryable)
  }
}
