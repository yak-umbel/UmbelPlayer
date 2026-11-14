import CoreGraphics
import CoreMedia
import Metal
import XCTest
import UmbelCore

final class PresentationControlsTests: XCTestCase {
  private final class HeldTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func session(for name: String = "seek_grid.mp4") throws -> PlaybackSession {
    PlaybackSession(source: try UmbelFileSource(url: fixture(name)), hostTime: HeldTime())
  }

  func testDefaultsAndValidatedRangesArePublic() async throws {
    let session = try session()
    let initialAspect = await session.aspectRatio
    let initialScaling = await session.pictureScaling
    let initialSubtitleDelay = await session.subtitleDelay
    let initialSubtitleScale = await session.subtitleScale
    let initialAudioDelay = await session.audioDelay
    XCTAssertNil(initialAspect)
    XCTAssertEqual(initialScaling, .fit)
    XCTAssertEqual(initialSubtitleDelay, 0)
    XCTAssertEqual(initialSubtitleScale, 1)
    XCTAssertEqual(initialAudioDelay, 0)

    await session.setAspectRatio(2)
    await session.setAspectRatio(0)
    await session.setAspectRatio(-1)
    await session.setAspectRatio(.nan)
    let validAspect = await session.aspectRatio
    XCTAssertEqual(validAspect, 2)
    await session.setSubtitleDelay(1)
    await session.setSubtitleDelay(.nan)
    let validSubtitleDelay = await session.subtitleDelay
    XCTAssertEqual(validSubtitleDelay, 1)
    await session.setSubtitleScale(10)
    let largeSubtitleScale = await session.subtitleScale
    XCTAssertEqual(largeSubtitleScale, 4)
    await session.setSubtitleScale(0.1)
    let smallSubtitleScale = await session.subtitleScale
    XCTAssertEqual(smallSubtitleScale, 0.25)
    await session.setAudioDelay(20)
    let maximumAudioDelay = await session.audioDelay
    XCTAssertEqual(maximumAudioDelay, 10)
    await session.setAudioDelay(.nan)
    let stillMaximum = await session.audioDelay
    XCTAssertEqual(stillMaximum, 10)
    await session.setAspectRatio(nil)
    let restoredAspect = await session.aspectRatio
    XCTAssertNil(restoredAspect)
  }

  func testSettingsBeforeLoadAffectSnapshotAndStayThroughSeek() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("hevc10_white.mp4")),
      videoRenderer: renderer, hostTime: HeldTime())
    await session.setAspectRatio(2)
    await session.setPictureScaling(.fill)
    await session.setSubtitleDelay(-0.5)
    await session.setSubtitleScale(1.5)
    await session.setAudioDelay(0.2)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let image = try await session.snapshot()
    XCTAssertEqual(image.width, image.height * 2)
    try await session.seek(to: .zero)
    let aspect = await session.aspectRatio
    let scaling = await session.pictureScaling
    let subtitleDelay = await session.subtitleDelay
    let subtitleScale = await session.subtitleScale
    let audioDelay = await session.audioDelay
    XCTAssertEqual(aspect, 2)
    XCTAssertEqual(scaling, .fill)
    XCTAssertEqual(subtitleDelay, -0.5)
    XCTAssertEqual(subtitleScale, 1.5)
    XCTAssertEqual(audioDelay, 0.2)
  }

  func testSubtitleDelayAndScaleAffectPublicSubtitleResults() async throws {
    let session = try session()
    try await session.load()
    addTeardownBlock { await session.stop() }
    let track = try await session.addExternalSubtitle(
      UmbelFileSource(url: fixture("external_gbk.srt")))
    try await session.selectSubtitleTrack(track.id)
    await session.setSubtitleDelay(1)
    try await session.seek(to: CMTime(seconds: 1.5, preferredTimescale: 600))
    let early = await session.currentSubtitleCues
    XCTAssertTrue(early.isEmpty)
    try await session.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600))
    let late = await session.currentSubtitleCues
    XCTAssertFalse(late.isEmpty)
    let canvas = CGSize(width: 640, height: 360)
    let normal = await session.renderSubtitles(in: canvas)
    await session.setSubtitleScale(2)
    let large = await session.renderSubtitles(in: canvas)
    XCTAssertGreaterThan(large.bitmaps.first?.frame.height ?? 0,
                         (normal.bitmaps.first?.frame.height ?? 0) * 1.5)
  }

  func testPictureFrameTracksFittingFillingAndAspectRatio() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(
      device: device, outputSize: CGSize(width: 64, height: 32),
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("hevc10_white.mp4")),
      videoRenderer: renderer, hostTime: HeldTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    let before = await session.pictureFrame
    XCTAssertNil(before)
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let fittedValue = await session.pictureFrame
    let fitted = try XCTUnwrap(fittedValue)
    XCTAssertEqual(fitted, CGRect(x: 10.0 / 64, y: 0, width: 43.0 / 64, height: 1))

    await session.setPictureScaling(.fill)
    _ = try await session.renderVideoFrame()
    let filledValue = await session.pictureFrame
    let filled = try XCTUnwrap(filledValue)
    XCTAssertEqual(filled, CGRect(x: 0, y: -0.25, width: 1, height: 1.5))

    await session.setPictureScaling(.fit)
    await session.setAspectRatio(2)
    _ = try await session.renderVideoFrame()
    let wideValue = await session.pictureFrame
    let wide = try XCTUnwrap(wideValue)
    XCTAssertEqual(wide, CGRect(x: 0, y: 0, width: 1, height: 1))
  }
}
