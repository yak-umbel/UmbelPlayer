import CoreMedia
import XCTest
@testable import UmbelCore

/// When the system drops what the renderer held — another output device, a
/// change of rate — what has not played is handed over again; when the
/// renderer fails, a new one takes over, once.
final class SampleBufferAudioRecoveryTests: XCTestCase {
  private let bench = AudioOutputBench()
  private var output: SampleBufferAudioOutput { bench.output }
  private var timeline: TimelineDouble { bench.timeline }
  private var host: TimelineHostTime { bench.host }
  private var maker: RendererMaker { bench.maker }
  private func frame(at seconds: Double, channels: Int = 2) -> AudioFrame { bench.frame(at: seconds, channels: channels) }
  private func renderer() throws -> AudioRendererDouble { try bench.renderer() }
  private func waitUntil(_ condition: () -> Bool) async throws { try await bench.waitUntil(condition) }

  /// Ten frames from 0 to 1 s; the timeline at 0.45. The frame from 0.4
  /// has not played through: from it on, all go again, in order.
  func testADiscardHandsOverAgainWhatHasNotPlayed() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    for index in 0..<10 { try await output.enqueue(frame(at: Double(index) / 10)) }
    timeline.set(rate: 0, time: CMTime(seconds: 0.45, preferredTimescale: 600))
    let renderer = try renderer()
    renderer.discard()
    try await waitUntil { renderer.holding.count == 6 }
    XCTAssertEqual(renderer.holding, [0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
    XCTAssertEqual(renderer.flushCount, 1, "flushed once more first, as the system advises")
  }

  /// After a seek nothing from before it comes back.
  func testAfterAFlushADiscardHandsOverNothing() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    for index in 0..<5 { try await output.enqueue(frame(at: Double(index) / 10)) }
    await output.flush()
    let renderer = try renderer()
    renderer.discard()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(renderer.holding, [])
  }

  /// A failed renderer is taken off the timeline and a new one put on,
  /// given what has not played and then the frame at hand.
  func testAFailedRendererIsReplacedAndPlaysOn() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(frame(at: 0))
    try await output.enqueue(frame(at: 0.1))
    let first = try renderer()
    first.fails = true
    try await output.enqueue(frame(at: 0.2))
    let second = try renderer()
    XCTAssertFalse(first === second)
    XCTAssertFalse(timeline.holds(first.queued.renderer))
    XCTAssertTrue(timeline.holds(second.queued.renderer))
    XCTAssertEqual(second.holding, [0, 0.1, 0.2])
  }

  /// Failing again on the same track is reported: a session then fails
  /// with the reason, and a host can open the film with the engine output.
  func testASecondFailureIsReported() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try renderer().fails = true
    try await output.enqueue(frame(at: 0))
    try renderer().fails = true
    do {
      try await output.enqueue(frame(at: 0.1))
      XCTFail("a second failure went unreported")
    } catch UmbelError.audioOutputUnavailable(let reason) {
      XCTAssertTrue(reason.contains("the double's reason"), "the system's reason goes along: \(reason)")
    }
  }

  /// A new track may be replaced once more.
  func testPreparingAgainAllowsAnotherReplacement() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try renderer().fails = true
    try await output.enqueue(frame(at: 0))
    try await output.prepare(sampleRate: 48_000, channelCount: 6)
    try renderer().fails = true
    try await output.enqueue(frame(at: 0.1, channels: 6))
    XCTAssertEqual(maker.made.count, 3)
  }

  /// A renderer made after the level was set — the first, or one replacing
  /// a failed one — plays at that level.
  func testTheLevelGoesToEveryRendererMade() async throws {
    await output.setVolume(0.2, muted: true)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(frame(at: 0))
    let first = try renderer()
    XCTAssertEqual(first.volume, 0.2)
    XCTAssertTrue(first.isMuted)
    first.fails = true
    try await output.enqueue(frame(at: 0.1))
    let second = try renderer()
    XCTAssertFalse(first === second)
    XCTAssertEqual(second.volume, 0.2)
    XCTAssertTrue(second.isMuted)
  }

  /// Never set, a renderer keeps the level it was made with: a test's
  /// silent renderer stays silent.
  func testWithoutALevelARendererKeepsItsOwn() async throws {
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    let renderer = try renderer()
    XCTAssertEqual(renderer.volume, 1)
    XCTAssertFalse(renderer.isMuted)
  }
  func testDiagnosticsReportWhatTheOutputRestoresAfterDiscard() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    await (output as? any PlaybackDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics)
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    for index in 0..<10 { try await output.enqueue(frame(at: Double(index) / 10)) }
    timeline.set(rate: 0, time: CMTime(seconds: 0.45, preferredTimescale: 600))
    try renderer().discard()
    for _ in 0..<100 {
      if diagnostics.snapshot().events.contains(where: { $0.name == "audio_output_restore" }) { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.name == "audio_output_restore" })
    XCTAssertEqual(event.values["playhead"], 0.45)
    XCTAssertEqual(event.values["retainedCount"], 6)
    XCTAssertEqual(event.values["firstPTS"], 0.4)
    XCTAssertEqual(event.values["lastEnd"], 1)
    XCTAssertEqual(try renderer().holding, [0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
  }

}
