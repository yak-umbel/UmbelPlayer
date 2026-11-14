import CoreMedia
import XCTest
import UmbelCore
@testable import UmbelUI

/// A renderer that shows nothing; picture in picture here is about what the
/// window asks of playback, not about drawing.
private actor BlankRenderer: VideoRenderer {
  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// What picture in picture's window asks of playback and tells it: its play,
/// pause and skip buttons, whether it is paused, how long the film is, and
/// taking the picture over while it is open.
@MainActor
final class PictureInPicturePlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func playback() async throws -> PictureInPicturePlayback {
    let renderer = SwitchingVideoRenderer(main: BlankRenderer(), pictureInPicture: BlankRenderer())
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("seek_grid.mp4")), videoRenderer: renderer)
    try await session.load()
    addTeardownBlock { await session.stop() }
    return PictureInPicturePlayback(session: session, renderer: renderer)
  }

  private func waitFor(_ phase: UmbelPlaybackPhase, in session: PlaybackSession) async throws {
    for _ in 0..<200 {
      if await session.phase == phase { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("not \(phase) within two seconds")
  }

  func testPlayAndPauseReachTheSession() async throws {
    let playback = try await playback()
    await playback.refresh()
    XCTAssertTrue(playback.isPaused, "loaded, not yet playing")
    await playback.setPlaying(true)
    XCTAssertFalse(playback.isPaused)
    try await waitFor(.playing, in: playback.session)
    await playback.setPlaying(false)
    XCTAssertTrue(playback.isPaused)
    try await waitFor(.paused, in: playback.session)
  }

  /// The window's skip buttons move playback on or back from where it is.
  func testSkippingSeeks() async throws {
    let playback = try await playback()
    await playback.skip(by: CMTime(seconds: 10, preferredTimescale: 600))
    let now = await playback.session.currentTime
    XCTAssertEqual(now.seconds, 10, accuracy: 0.1)
    await playback.skip(by: CMTime(seconds: -15, preferredTimescale: 600))
    let back = await playback.session.currentTime
    XCTAssertEqual(back.seconds, 0, accuracy: 0.1, "held to the start")
  }

  func testThePlayableRangeIsTheDuration() async throws {
    let playback = try await playback()
    await playback.refresh()
    XCTAssertEqual(playback.timeRange.start.seconds, 0)
    XCTAssertEqual(playback.timeRange.duration.seconds, 30, accuracy: 0.1)
  }

  /// A live stream has no end: its range is open both ways, as the system
  /// asks, not a range of nothing.
  func testALiveStreamHasNoEnd() {
    let range = PictureInPicturePlayback.timeRange(forDuration: .indefinite)
    XCTAssertEqual(range.start, .negativeInfinity)
    XCTAssertEqual(range.duration, .positiveInfinity)
  }

  func testStartingAndStoppingSwitchesTheRenderer() async throws {
    let playback = try await playback()
    await playback.started()
    var shown = await playback.renderer.active
    XCTAssertEqual(shown, .pictureInPicture)
    await playback.stopped()
    shown = await playback.renderer.active
    XCTAssertEqual(shown, .main)
  }

  /// A change of state the window did not make — the host paused — reaches
  /// the window's buttons.
  func testAPauseFromElsewhereIsReported() async throws {
    let playback = try await playback()
    var changes = 0
    playback.onChange = { changes += 1 }
    try await playback.session.play()
    try await waitFor(.playing, in: playback.session)
    await playback.refresh()
    await playback.session.pause()
    await playback.refresh()
    XCTAssertEqual(changes, 2)
  }
}
