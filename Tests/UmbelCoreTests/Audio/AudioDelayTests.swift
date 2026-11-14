import CoreMedia
import XCTest
@testable import UmbelCore

final class AudioDelayTests: XCTestCase {
  private final class FixedTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private actor RecordingOutput: AudioOutput {
    private var recorded: [AudioFrame] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    var frames: [AudioFrame] { recorded }
    private(set) var flushCount = 0
    var currentAnchor: RenderAnchor? { nil }
    func prepare(sampleRate: Double, channelCount: Int) async throws {}
    func enqueue(_ frame: AudioFrame) async throws {
      let started = generation
      while recorded.count >= 20 {
        await withCheckedContinuation { waiters.append($0) }
      }
      guard started == generation else { return }
      recorded.append(frame)
    }
    func flush() async {
      generation += 1
      flushCount += 1
      recorded.removeAll()
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.resume() }
    }
    func start() async throws {}
    func pause() async {}
    func stop() async {}
    func setRate(_ rate: Double) async {}
    func setVolume(_ volume: Float, muted: Bool) async {}
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func frame(at time: Double, samples: [Float]) -> AudioFrame {
    AudioFrame(
      presentationTime: CMTime(seconds: time, preferredTimescale: 10),
      sampleRate: 10, channelCount: 1, frameCount: samples.count, samples: samples)
  }

  func testPositiveDelayStartsWithSilenceAndKeepsTheClockOrigin() {
    var delay = AudioDelayProcessor(seconds: 0.3)
    let frames = delay.process(frame(at: 5, samples: [1, 2, 3, 4]))

    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames[0].presentationTime.seconds, 5, accuracy: 0.001)
    XCTAssertEqual(frames[0].samples, [0, 0, 0])
    XCTAssertEqual(frames[1].presentationTime.seconds, 5.3, accuracy: 0.001)
    XCTAssertEqual(frames[1].samples, [1, 2, 3, 4])
  }

  func testNegativeDelaySkipsSoundWhileKeepingTheClockOrigin() {
    var delay = AudioDelayProcessor(seconds: -0.3)
    let first = delay.process(frame(at: 5, samples: [1, 2]))
    let second = delay.process(frame(at: 5.2, samples: [3, 4, 5, 6]))

    XCTAssertTrue(first.isEmpty)
    XCTAssertEqual(second.count, 1)
    XCTAssertEqual(second[0].presentationTime.seconds, 5, accuracy: 0.001)
    XCTAssertEqual(second[0].samples, [4, 5, 6])
  }

  func testZeroDelayPreservesTheFrame() {
    var delay = AudioDelayProcessor(seconds: 0)
    let input = frame(at: 5, samples: [1, 2])
    let output = delay.process(input)
    XCTAssertEqual(output.count, 1)
    XCTAssertEqual(output[0].presentationTime, input.presentationTime)
    XCTAssertEqual(output[0].samples, input.samples)
  }

  func testSessionDelaysSoundBeforeLoadWithoutMovingProgress() async throws {
    let output = RecordingOutput()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("seek_grid.mp4")),
      audioOutput: output, hostTime: FixedTime())
    addTeardownBlock { await session.stop() }

    await session.setAudioDelay(0.3)
    try await session.load()
    try await session.play()
    var frames: [AudioFrame] = []
    for _ in 0..<100 {
      frames = await output.frames
      if frames.count >= 2 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThanOrEqual(frames.count, 2)
    guard frames.count >= 2 else { return }
    XCTAssertTrue(frames[0].samples.allSatisfy { $0 == 0 })
    XCTAssertEqual(
      frames[1].presentationTime.seconds - frames[0].presentationTime.seconds,
      0.3, accuracy: 0.002)
    let progress = await session.currentTime
    XCTAssertEqual(progress.seconds, 0, accuracy: 0.001)
  }

  func testChangingDelayWhilePausedPreservesQueuedAudioAndPosition() async throws {
    let output = RecordingOutput()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("seek_grid.mp4")),
      audioOutput: output, hostTime: FixedTime())
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    for _ in 0..<100 {
      if await output.frames.count >= 2 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await session.pause()
    let before = await output.flushCount
    let beforeFrames = await output.frames
    let beforeTime = await session.currentTime

    await session.setAudioDelay(0.3)

    let after = await output.flushCount
    XCTAssertEqual(after, before)
    let frames = await output.frames
    XCTAssertEqual(frames.first?.samples, beforeFrames.first?.samples)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
    let progress = await session.currentTime
    XCTAssertEqual(progress.seconds, beforeTime.seconds, accuracy: 0.001)
  }

  func testContinuousDelayChangesKeepPCMOnOneOutputTimeline() {
    var timing = AudioTiming()
    let first = timing.frames(for: frame(at: 0, samples: [1, 2]), systemTimed: false)
    XCTAssertEqual(first[0].presentationTime.seconds, 0)
    timing.setDelay(CMTime(seconds: 0.3, preferredTimescale: 10))
    let later = timing.frames(for: frame(at: 0.2, samples: [3, 4]), systemTimed: false)
    XCTAssertEqual(later.map(\.samples), [[0, 0, 0], [3, 4]])
    XCTAssertEqual(later.map(\.presentationTime.seconds), [0.2, 0.5])
    timing.setDelay(CMTime(seconds: 0.1, preferredTimescale: 10))
    let skipped = timing.frames(for: frame(at: 0.4, samples: [5, 6]), systemTimed: false)
    XCTAssertTrue(skipped.isEmpty)
    let next = timing.frames(for: frame(at: 0.6, samples: [7, 8]), systemTimed: false)
    XCTAssertEqual(next.map(\.samples), [[7, 8]])
    XCTAssertEqual(next[0].presentationTime.seconds, 0.7, accuracy: 0.000001)
  }

  func testChangingDelayDuringPendingSkipDoesNotLoseTheRemainingAdjustment() {
    var timing = AudioTiming()
    timing.setDelay(CMTime(seconds: -0.5, preferredTimescale: 10))
    XCTAssertTrue(timing.frames(for: frame(at: 0, samples: [1, 2]), systemTimed: false).isEmpty)
    timing.setDelay(CMTime(seconds: -0.4, preferredTimescale: 10))
    XCTAssertTrue(timing.frames(for: frame(at: 0.2, samples: [3, 4]), systemTimed: false).isEmpty)
    let next = timing.frames(for: frame(at: 0.4, samples: [5, 6]), systemTimed: false)
    XCTAssertEqual(next.map(\.samples), [[5, 6]])
    XCTAssertEqual(next[0].presentationTime.seconds, 0, accuracy: 0.000001)
  }

  func testSystemTimedDelayReductionDoesNotOverlapAlreadyQueuedSamples() {
    var timing = AudioTiming()
    _ = timing.frames(for: frame(at: 0, samples: [1, 2]), systemTimed: true)
    _ = timing.frames(for: frame(at: 0.2, samples: [3, 4]), systemTimed: true)
    timing.setDelay(CMTime(seconds: -0.1, preferredTimescale: 10))
    let next = timing.frames(for: frame(at: 0.4, samples: [5, 6]), systemTimed: true)
    XCTAssertEqual(next.map(\.samples), [[6]])
    XCTAssertEqual(next[0].presentationTime.seconds, 0.4, accuracy: 0.000001)
    timing.setDelay(CMTime(seconds: 0.1, preferredTimescale: 10))
    let later = timing.frames(for: frame(at: 0.6, samples: [7, 8]), systemTimed: true)
    XCTAssertEqual(later.map(\.samples), [[7, 8]])
    XCTAssertEqual(later[0].presentationTime.seconds, 0.7, accuracy: 0.000001)
  }

  func testTimestampDiscontinuitiesDoNotBecomeUnboundedDelayAdjustments() {
    for systemTimed in [false, true] {
      var timing = AudioTiming()
      timing.setDelay(CMTime(seconds: 0.3, preferredTimescale: 10))
      _ = timing.frames(for: frame(at: 0, samples: [1, 2]), systemTimed: systemTimed)
      let forward = timing.frames(for: frame(at: 1_000, samples: [3, 4]), systemTimed: systemTimed)
      XCTAssertEqual(forward.reduce(0) { $0 + $1.frameCount }, systemTimed ? 2 : 5)
      XCTAssertEqual(forward.last?.samples, [3, 4])
      XCTAssertEqual(forward.last?.presentationTime.seconds ?? -1, 1_000.3, accuracy: 0.000001)
      let backward = timing.frames(for: frame(at: 0, samples: [5, 6]), systemTimed: systemTimed)
      XCTAssertEqual(backward.last?.samples, [5, 6])
      XCTAssertEqual(backward.last?.presentationTime.seconds ?? -1, 0.3, accuracy: 0.000001)
    }
  }

  func testDelayStartsAgainAfterSwitchingAudioTracks() async throws {
    let output = RecordingOutput()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("multi_track.mkv")),
      audioOutput: output, hostTime: FixedTime())
    addTeardownBlock { await session.stop() }
    await session.setAudioDelay(0.2)
    try await session.load()
    try await session.play()
    for _ in 0..<100 {
      if await output.frames.count >= 2 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let tracks = await session.tracks
    let selected = await session.selectedAudioTrack
    let other = try XCTUnwrap(tracks.first { $0.kind == .audio && $0.id != selected })

    try await session.selectAudioTrack(other.id)

    var frames: [AudioFrame] = []
    for _ in 0..<100 {
      frames = await output.frames
      if frames.count >= 2 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThanOrEqual(frames.count, 2)
    guard frames.count >= 2 else { return }
    XCTAssertTrue(frames[0].samples.allSatisfy { $0 == 0 })
    XCTAssertEqual(frames[1].presentationTime.seconds - frames[0].presentationTime.seconds,
                   0.2, accuracy: 0.002)
  }
}
