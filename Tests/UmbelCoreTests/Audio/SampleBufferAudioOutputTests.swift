import CoreMedia
import XCTest
@testable import UmbelCore

/// An output on doubles, and what its tests need: shared by the output's
/// tests and its recovery tests.
final class AudioOutputBench: @unchecked Sendable {
  let host: TimelineHostTime
  let timeline: TimelineDouble
  let maker: RendererMaker
  let output: SampleBufferAudioOutput

  init() {
    let host = TimelineHostTime(), maker = RendererMaker()
    let timeline = TimelineDouble(host: host)
    self.host = host
    self.maker = maker
    self.timeline = timeline
    output = SampleBufferAudioOutput(timeline: timeline) { maker.make($0) }
  }

  func frame(at seconds: Double, length: Double = 0.1, channels: Int = 2) -> AudioFrame {
    let count = Int(length * 48_000)
    return AudioFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 48_000), sampleRate: 48_000,
      channelCount: channels, frameCount: count, samples: [Float](repeating: 0, count: count * channels))
  }

  /// The renderer made last: the one in use.
  func renderer() throws -> AudioRendererDouble { try XCTUnwrap(maker.made.last) }

  func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
  }
}

/// The output built on the system's sample buffer renderer: frames go to it
/// as samples, a full renderer holds them back, and the timeline — the
/// clock's to set — is never moved from here.
final class SampleBufferAudioOutputTests: XCTestCase {
  private let bench = AudioOutputBench()
  private var output: SampleBufferAudioOutput { bench.output }
  private var timeline: TimelineDouble { bench.timeline }
  private func frame(at seconds: Double, channels: Int = 2) -> AudioFrame { bench.frame(at: seconds, channels: channels) }
  private func renderer() throws -> AudioRendererDouble { try bench.renderer() }

  func testPreparingPutsARendererOnTheTimeline() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    XCTAssertTrue(timeline.holds(try renderer().queued.renderer))
  }

  func testFramesReachTheRendererAtTheirTimes() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(frame(at: 3.0))
    try await output.enqueue(frame(at: 3.1, channels: 6))
    XCTAssertEqual(try renderer().holding, [3.0, 3.1])
  }

  /// The backpressure: a renderer that has enough holds the next frame
  /// back until it takes more.
  func testAFullRendererHoldsTheNextFrameBack() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    let renderer = try renderer()
    renderer.isReady = false
    let output = self.output, frame = self.frame(at: 1)
    let waiting = Task { try await output.enqueue(frame) }
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(renderer.holding, [])
    renderer.isReady = true
    try await waiting.value
    XCTAssertEqual(renderer.holding, [1])
  }

  /// A seek flushes: a frame waiting for room is let go and not handed over.
  func testAFlushLetsAWaitingFrameGo() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    let renderer = try renderer()
    renderer.isReady = false
    let output = self.output, frame = self.frame(at: 1)
    let waiting = Task { try await output.enqueue(frame) }
    try await Task.sleep(nanoseconds: 30_000_000)
    await output.flush()
    try await waiting.value
    renderer.isReady = true
    XCTAssertEqual(renderer.holding, [])
    XCTAssertEqual(renderer.flushCount, 1)
  }

  /// Feeding cancelled — a stop or a seek — lets a frame waiting for room go
  /// at once, not handed over: paused, a full renderer takes nothing more,
  /// and waiting on regardless would spin until the flush that follows.
  func testACancelledFrameStopsWaiting() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    let renderer = try renderer()
    renderer.isReady = false
    let output = self.output, frame = self.frame(at: 1)
    let returned = expectation(description: "the cancelled frame stops waiting")
    let waiting = Task {
      try? await output.enqueue(frame)
      returned.fulfill()
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    waiting.cancel()
    await fulfillment(of: [returned], timeout: 0.5)
    renderer.isReady = true
    XCTAssertEqual(renderer.holding, [])
  }

  /// TrueHD's frames, 40 samples each, reach the renderer joined into 20 ms
  /// ones: in 40-sample buffers it played a blip and then nothing.
  func testTinyFramesReachTheRendererJoined() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 6)
    for index in 0..<48 {
      try await output.enqueue(AudioFrame(
        presentationTime: CMTime(value: CMTimeValue(index * 40), timescale: 48_000), sampleRate: 48_000,
        channelCount: 6, frameCount: 40, samples: [Float](repeating: 0.1, count: 240)))
    }
    let renderer = try renderer()
    XCTAssertEqual(renderer.holdingLengths, [960, 960])
    XCTAssertEqual(renderer.holding, [0, 0.02])
  }

  /// Playing, pausing and the rate are the clock's to set on the timeline.
  func testTheOutputNeverMovesTheTimeline() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.start()
    await output.setRate(2)
    await output.pause()
    XCTAssertEqual(timeline.sets, [])
    let anchor = await output.currentAnchor
    XCTAssertNil(anchor, "the clock reads the timeline; there are no anchors to adopt")
  }

  func testNothingPlaysBeforePreparing() async throws {
    do {
      try await output.start()
      XCTFail("started unprepared")
    } catch UmbelError.audioOutputUnavailable {}
    do {
      try await output.enqueue(frame(at: 0))
      XCTFail("took a frame unprepared")
    } catch UmbelError.audioOutputUnavailable {}
  }
}
