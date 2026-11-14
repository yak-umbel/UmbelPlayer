import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// HDR films through a whole session: decoded, hardware first, and drawn.
///
/// hdr10_pq.mp4 holds codes 723 over 450 — 1004.19 and 50.19 nits, 10.042
/// and 0.5019 in the renderer's linear light; hlg.mp4 721 over 502, signals
/// 0.75 and 0.5, scene light 3.1796 and 1 on the system's 0...12 scale.
final class HDRPlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// Top and bottom halves of the first picture shown.
  private func halves(
    of name: String, dynamicRange: UmbelDynamicRange
  ) async throws -> (top: Float, bottom: Float) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, dynamicRange: dynamicRange,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture(name)), videoRenderer: renderer, hostTime: HeldHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    var shown: PresentedFrame?
    for _ in 0..<200 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    XCTAssertNotNil(shown, name)
    let top = try await renderer.readValue(x: 160, y: 60)
    let bottom = try await renderer.readValue(x: 160, y: 180)
    return (top.g, bottom.g)
  }

  func testPQPlaysAsHDR() async throws {
    let values = try await halves(of: "hdr10_pq.mp4", dynamicRange: .automatic)
    XCTAssertEqual(values.top, 10.042, accuracy: 0.02)
    XCTAssertEqual(values.bottom, 0.5019, accuracy: 0.002)
  }

  func testHLGPlaysAsHDR() async throws {
    let values = try await halves(of: "hlg.mp4", dynamicRange: .automatic)
    XCTAssertEqual(values.top, 3.1796, accuracy: 0.01)
    XCTAssertEqual(values.bottom, 1, accuracy: 0.01)
  }

  /// Asked for standard range, the same film is tone-mapped: its 1000-nit
  /// peak (MaxCLL 1000 in the fixture) is SDR white, 50 nits stays 50.
  func testPQPlaysToneMappedWhenAskedForStandardRange() async throws {
    let values = try await halves(of: "hdr10_pq.mp4", dynamicRange: .standard)
    XCTAssertEqual(values.top, 1, accuracy: 0.006)
    XCTAssertEqual(values.bottom, 0.2472, accuracy: 0.006, "linear light relative to SDR white")
  }
}
