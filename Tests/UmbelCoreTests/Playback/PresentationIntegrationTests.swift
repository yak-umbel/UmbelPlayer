import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

final class PresentationIntegrationTests: XCTestCase {
  private final class HeldClock: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func seekAndShow(_ seconds: Double, session: PlaybackSession) async throws {
    try await session.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("seek did not produce a visible picture")
  }

  private func bytes(_ image: CGImage) throws -> Data {
    try XCTUnwrap(image.dataProvider?.data) as Data
  }

  func testExternalSUPInBothSlotsKeepsTimingAndPausedSnapshotPlacement() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")),
      videoRenderer: renderer, hostTime: HeldClock())
    try await session.load()
    addTeardownBlock { await session.stop() }
    let track = try await session.addExternalSubtitle(
      UmbelFileSource(url: fixture("external_tiny.sup")))
    try await session.selectSubtitleTrack(track.id)
    try await session.selectSubtitleTrack(track.id, for: .secondary)
    try await seekAndShow(2.5, session: session)
    await session.pause()

    let both = try await session.snapshot()
    let pixels = try bytes(both)
    XCTAssertEqual(both.width, 320)
    XCTAssertEqual(both.height, 240)
    for y in [162, 210] {
      XCTAssertGreaterThan(pixels[y * both.bytesPerRow + 160 * 4], 240)
      let displayed = try await renderer.readPixel(x: 160, y: y)
      XCTAssertGreaterThan(displayed.r, 240)
    }

    await session.setVideoAdjustments(.init(brightness: 0.2))
    let adjusted = try await session.snapshot()
    let adjustedPixels = try bytes(adjusted)
    XCTAssertGreaterThan(adjustedPixels[100 * adjusted.bytesPerRow + 160 * 4], 40)
    for y in [162, 210] {
      XCTAssertEqual(adjustedPixels[y * adjusted.bytesPerRow + 160 * 4],
                     pixels[y * both.bytesPerRow + 160 * 4])
      let displayed = try await renderer.readPixel(x: 160, y: y)
      XCTAssertEqual(displayed.r, adjustedPixels[y * adjusted.bytesPerRow + 160 * 4], accuracy: 1)
    }
    let mediaURL = fixture("sync_check.mp4")
    let previews = UmbelThumbnailGenerator { try UmbelFileSource(url: mediaURL) }
    let position = await session.currentTime
    let preview = try await previews.thumbnail(
      at: position, maximumSize: CGSize(width: 320, height: 240))
    let previewPixels = try bytes(preview.image)
    for y in [100, 162, 210] {
      XCTAssertLessThan(previewPixels[y * preview.image.bytesPerRow + 160 * 4], 30,
                        "previews contain neutral video without either subtitle slot")
    }
    let afterPreview = try await session.snapshot()
    XCTAssertEqual(try bytes(afterPreview), adjustedPixels)
    let settings = await session.videoAdjustments
    let afterPosition = await session.currentTime
    XCTAssertEqual(settings, .init(brightness: 0.2))
    XCTAssertEqual(afterPosition, position)
    await session.setVideoAdjustments(.init())
    let reset = try await session.snapshot()
    XCTAssertEqual(try bytes(reset), pixels)

    await session.setSubtitleDelay(1, for: .secondary)
    let delayed = try await session.snapshot()
    let delayedPixels = try bytes(delayed)
    XCTAssertLessThan(delayedPixels[162 * delayed.bytesPerRow + 160 * 4], 30)
    XCTAssertGreaterThan(delayedPixels[210 * delayed.bytesPerRow + 160 * 4], 240)
    let displayed = try await renderer.readPixel(x: 160, y: 162)
    XCTAssertLessThan(displayed.r, 30)
    await session.setSubtitleDelay(0, for: .secondary)

    try await seekAndShow(3.75, session: session)
    let cleared = try await session.snapshot()
    let video = try await session.snapshot(includingSubtitles: false)
    XCTAssertEqual(try bytes(cleared), try bytes(video))
    try await seekAndShow(2.5, session: session)
    let restored = try await session.snapshot()
    XCTAssertEqual(try bytes(restored), pixels)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
  }
}
