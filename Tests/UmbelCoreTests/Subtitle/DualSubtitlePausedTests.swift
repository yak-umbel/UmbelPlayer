import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

final class DualSubtitlePausedTests: XCTestCase {
  private final class HeldClock: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func bytes(_ image: CGImage) throws -> [UInt8] {
    [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
  }

  /// Check the actual displayed texture; taking a snapshot alone cannot prove a paused redraw.
  private func matchesDisplay(_ session: PlaybackSession, _ renderer: OffscreenVideoRenderer) async throws {
    func sRGB(_ code: UInt8) -> Int {
      let signal = Double(code) / 255
      let light = signal < 0.081 ? signal / 4.5 : pow((signal + 0.099) / 1.099, 1 / 0.45)
      let value = light <= 0.0031308 ? light * 12.92 : 1.055 * pow(light, 1 / 2.4) - 0.055
      return Int((value * 255).rounded())
    }
    let image = try await session.snapshot()
    let expected = try bytes(image)
    var maximumDifference = 0
    for y in stride(from: 0, to: image.height, by: 3) {
      for x in stride(from: 0, to: image.width, by: 3) {
        let pixel = try await renderer.readPixel(x: x, y: y)
        let offset = (y * image.width + x) * 4
        maximumDifference = max(maximumDifference,
          abs(sRGB(pixel.b) - Int(expected[offset])),
          abs(sRGB(pixel.g) - Int(expected[offset + 1])),
          abs(sRGB(pixel.r) - Int(expected[offset + 2])))
      }
    }
    XCTAssertLessThanOrEqual(maximumDifference, 2, "paused screen and snapshot use the same layers/settings")
  }

  func testPausedSelectionDelayScalePlacementAndDisableRedrawBothLayers() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("styled_subs.mkv")),
      videoRenderer: renderer, hostTime: HeldClock())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    var presented = false
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { presented = true; break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(presented)
    await session.pause()
    let track = try await session.addExternalSubtitle(try UmbelFileSource(url: fixture("external_gbk.srt")))
    try await session.selectSubtitleTrack(track.id)
    let primary = try bytes(await session.snapshot())
    try await session.selectSubtitleTrack(track.id, for: .secondary)
    let both = try bytes(await session.snapshot())
    XCTAssertNotEqual(primary, both)
    try await matchesDisplay(session, renderer)

    await session.setSubtitleScale(1.5, for: .secondary)
    await session.setSubtitlePlacement(.init(verticalOffset: 0.4), for: .secondary)
    let moved = try bytes(await session.snapshot())
    XCTAssertNotEqual(moved, both)
    try await matchesDisplay(session, renderer)

    await session.setSubtitleDelay(2, for: .secondary)
    let delayed = try bytes(await session.snapshot())
    XCTAssertEqual(delayed, primary)
    try await matchesDisplay(session, renderer)
    await session.setSubtitleDelay(0, for: .secondary)
    try await session.selectSubtitleTrack(nil, for: .secondary)
    let disabled = try bytes(await session.snapshot())
    XCTAssertEqual(disabled, primary)
    try await matchesDisplay(session, renderer)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
  }
}
