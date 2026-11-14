import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// An output that, like the real engine, refuses to start before it has
/// been prepared, and counts the starts it was asked for.
private actor StrictAudioOutput: AudioOutput {
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Float, muted: Bool) {}
  private var isPrepared = false
  private(set) var starts = 0
  private(set) var isRunning = false

  func prepare(sampleRate: Double, channelCount: Int) async throws { isPrepared = true }
  func enqueue(_ frame: AudioFrame) async throws {}
  func flush() async {}
  func start() async throws {
    starts += 1
    guard isPrepared else { throw UmbelError.audioOutputUnavailable(reason: "not prepared") }
    isRunning = true
  }
  func pause() async { isRunning = false }
  func stop() async { isRunning = false }
  var currentAnchor: RenderAnchor? { nil }
}

/// A host passes an audio output whatever the film; a film without sound
/// must still play. The output has nothing to play and is left alone.
final class VideoOnlyPlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  func testAFilmWithoutSoundPlaysWithAnOutputGiven() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let output = StrictAudioOutput()
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("pgs_subs.mkv")), audioOutput: output,
      videoRenderer: renderer, hostTime: HeldHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    var shown: PresentedFrame?
    for _ in 0..<200 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    XCTAssertNotNil(shown, "a picture")
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed)
    let reason = await session.failureReason
    XCTAssertNil(reason)
    let starts = await output.starts
    XCTAssertEqual(starts, 0, "no sound to play, so the output is never started")
  }

  /// Turning the sound off mid-play pauses the output too; turning it on
  /// again starts it.
  func testTurningTheSoundOffPausesTheOutput() async throws {
    let output = StrictAudioOutput()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("seek_grid.mp4")), audioOutput: output,
      hostTime: HeldHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<200 {
      if await output.isRunning { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let runningBefore = await output.isRunning
    XCTAssertTrue(runningBefore)

    try await session.selectAudioTrack(nil)
    let runningAfter = await output.isRunning
    XCTAssertFalse(runningAfter, "nothing to play")

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    try await session.selectAudioTrack(audio.id)
    let runningAgain = await output.isRunning
    XCTAssertTrue(runningAgain)
  }
}
