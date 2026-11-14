import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Bitmap subtitle tracks through a whole session, drawn for the host.
///
/// The fixtures place a white block at (110, 200) 100×20 from 0.5 s and a red
/// one at (40, 20) 60×30 from 2.5 s, on a 320×240 canvas. Drawn at twice
/// that, every coordinate doubles.
final class BitmapSubtitlePlaybackTests: XCTestCase {
  private let size = CGSize(width: 640, height: 480)

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// The fixtures have no audio, so a video renderer is what moves the
  /// stream along: subtitle packets ride with the video.
  private func play(
    _ name: String, compositing: Bool = true
  ) async throws -> (PlaybackSession, OffscreenVideoRenderer) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture(name)), videoRenderer: renderer,
      compositesSubtitles: compositing, hostTime: HeldHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    let tracks = await session.tracks
    let subtitle = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await session.selectSubtitleTrack(subtitle.id)
    return (session, renderer)
  }

  private func session(_ name: String) async throws -> PlaybackSession {
    try await play(name, compositing: false).0
  }

  private func firstPicture(_ session: PlaybackSession) async throws -> UmbelSubtitleFrame {
    for _ in 0..<100 {
      let frame = await session.renderSubtitles(in: size)
      if !frame.bitmaps.isEmpty { return frame }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("nothing rendered")
    return UmbelSubtitleFrame(bitmaps: [], isChanged: false)
  }

  func testPGSTrackIsPlacedOnThePicture() async throws {
    let session = try await session("pgs_subs.mkv")
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    let drawn = try await firstPicture(session)
    XCTAssertEqual(drawn.bitmaps.map(\.frame), [CGRect(x: 220, y: 400, width: 200, height: 40)])
    XCTAssertEqual(drawn.bitmaps.first?.image.width, 100, "the stream's own pixels, scaled on display")
  }

  func testDVDTrackIsPlacedOnThePicture() async throws {
    let session = try await session("dvd_subs.mkv")
    try await session.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
    let drawn = try await firstPicture(session)
    XCTAssertEqual(drawn.bitmaps.map(\.frame), [CGRect(x: 80, y: 40, width: 120, height: 60)])
  }

  func testPlacementMovesDecodedBitmapCue() async throws {
    let session = try await session("pgs_subs.mkv")
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    _ = try await firstPicture(session)

    await session.setSubtitlePlacement(.init(verticalOffset: 0.1, bottomInset: 0.15))
    let placed = await session.renderSubtitles(in: size)
    XCTAssertTrue(placed.isChanged)
    XCTAssertEqual(placed.bitmaps.map(\.frame), [CGRect(x: 220, y: 352, width: 200, height: 40)])
  }

  // ── Composited by the player ─────────────────────────

  /// Green of one pixel of what the renderer drew.
  private func level(_ renderer: OffscreenVideoRenderer, x: Int, y: Int) async throws -> Int {
    Int(try await renderer.readPixel(x: x, y: y).g)
  }

  /// By default the player draws subtitles into the picture itself: the
  /// host only asks for frames.
  func testSubtitlesAreCompositedIntoThePictureByDefault() async throws {
    let (session, renderer) = try await play("pgs_subs.mkv")
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    var subtitle = 0
    for _ in 0..<100 {
      _ = try await session.renderVideoFrame()
      subtitle = try await level(renderer, x: 160, y: 210)
      if subtitle > 250 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThan(subtitle, 250, "the white block, in the picture")
    let picture = try await level(renderer, x: 160, y: 100)
    XCTAssertEqual(picture, 128, accuracy: 4, "grey picture around it")
  }

  func testPlacementRedrawsPausedPictureAndSnapshot() async throws {
    let (session, renderer) = try await play("pgs_subs.mkv")
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    var original = 0
    for _ in 0..<100 {
      _ = try await session.renderVideoFrame()
      original = try await level(renderer, x: 160, y: 210)
      if original > 250 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertGreaterThan(original, 250)
    await session.pause()
    let before = try await session.snapshot()

    await session.setSubtitlePlacement(.init(verticalOffset: 0.25))
    let oldSpot = try await level(renderer, x: 160, y: 210)
    let newSpot = try await level(renderer, x: 160, y: 150)
    XCTAssertEqual(oldSpot, 128, accuracy: 4)
    XCTAssertGreaterThan(newSpot, 250)

    let after = try await session.snapshot()
    XCTAssertEqual(before.width, 320)
    XCTAssertEqual(before.height, 240)
    XCTAssertEqual(after.width, before.width)
    XCTAssertEqual(after.height, before.height)
    let beforeBytes = try XCTUnwrap(before.dataProvider?.data) as Data
    let afterBytes = try XCTUnwrap(after.dataProvider?.data) as Data
    func green(_ bytes: Data, x: Int, y: Int) -> Int {
      Int(bytes[(y * 320 + x) * 4 + 1])
    }
    XCTAssertGreaterThan(green(beforeBytes, x: 160, y: 210), 250)
    XCTAssertEqual(green(afterBytes, x: 160, y: 210), 140, accuracy: 4, "BT.709 mid-grey exported into sRGB")
    XCTAssertGreaterThan(green(afterBytes, x: 160, y: 150), 250)
  }

  /// A host that draws subtitles itself turns compositing off, and the
  /// picture comes without them.
  func testCompositingCanBeTurnedOff() async throws {
    let (session, renderer) = try await play("pgs_subs.mkv", compositing: false)
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    let forHost = try await firstPicture(session)
    XCTAssertEqual(forHost.bitmaps.count, 1, "still there for the host to draw")
    // The subtitle can arrive before the first frame after the seek.
    var shown: PresentedFrame?
    for _ in 0..<100 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    XCTAssertNotNil(shown, "a picture to look at")
    let spot = try await level(renderer, x: 160, y: 210)
    XCTAssertEqual(spot, 128, accuracy: 4, "not in the picture")
  }
}
