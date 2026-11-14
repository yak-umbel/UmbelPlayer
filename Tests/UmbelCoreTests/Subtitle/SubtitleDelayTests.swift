import CoreMedia
import XCTest
@testable import UmbelCore

/// Subtitles later or earlier than the clock: the external file's first
/// line runs from 1 s to 5 s.
final class SubtitleDelayTests: XCTestCase {
  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func controller() async throws -> SubtitleController {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("seek_grid.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let controller = SubtitleController(demux: demux)
    let track = try await controller.addExternal(
      try UmbelFileSource(url: fixtureURL("external_gbk.srt")), language: nil, title: nil)
    try await controller.selectManually(track.id)
    return controller
  }

  private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

  func testALaterDelayShowsTheLineLater() async throws {
    let controller = try await controller()
    await controller.setDelay(1)
    let early = await controller.cues(atClock: at(1.5))
    let late = await controller.cues(atClock: at(2.5))
    XCTAssertTrue(early.isEmpty, "at 1.5 s the line, due at 1 s, waits until 2 s")
    XCTAssertFalse(late.isEmpty)
  }

  func testAnEarlierDelayShowsTheLineEarlier() async throws {
    let controller = try await controller()
    await controller.setDelay(-0.8)
    let shown = await controller.cues(atClock: at(0.5))
    XCTAssertFalse(shown.isEmpty, "due at 1 s, shown from 0.2 s")
  }

  /// Far earlier than anything read: nothing yet, and nothing breaks.
  func testADelayFarEarlierThanWhatIsReadShowsNothingYet() async throws {
    let controller = try await controller()
    await controller.setDelay(-100)
    let shown = await controller.cues(atClock: at(0.5))
    XCTAssertTrue(shown.isEmpty)
    let frame = await controller.render(
      at: at(0.5), in: CGSize(width: 320, height: 180),
      picture: CGRect(x: 0, y: 0, width: 320, height: 180), videoSize: nil)
    XCTAssertTrue(frame.bitmaps.isEmpty)
  }

  /// Rendering goes by the delay too: the picture a display loop draws.
  func testRenderingGoesByTheDelay() async throws {
    let controller = try await controller()
    await controller.setDelay(1)
    let canvas = CGSize(width: 320, height: 180)
    let whole = CGRect(origin: .zero, size: canvas)
    let before = await controller.render(at: at(1.5), in: canvas, picture: whole, videoSize: nil)
    let after = await controller.render(at: at(2.5), in: canvas, picture: whole, videoSize: nil)
    XCTAssertTrue(before.bitmaps.isEmpty)
    XCTAssertFalse(after.bitmaps.isEmpty)
  }

  func testSnapshotRenderingDoesNotReplaceTheScreenCache() async throws {
    let controller = try await controller()
    let canvas = CGSize(width: 320, height: 180)
    let whole = CGRect(origin: .zero, size: canvas)
    _ = await controller.render(at: at(1.5), in: canvas, picture: whole, videoSize: nil)
    let repeated = await controller.render(at: at(1.5), in: canvas, picture: whole, videoSize: nil)
    XCTAssertFalse(repeated.isChanged)

    let shot = await controller.snapshot(at: at(1.5), in: CGSize(width: 640, height: 360),
                                         videoSize: nil)
    XCTAssertFalse(shot.isEmpty)
    let screen = await controller.render(at: at(1.5), in: canvas, picture: whole, videoSize: nil)
    XCTAssertFalse(screen.isChanged)
  }
}
