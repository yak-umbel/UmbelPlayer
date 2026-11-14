import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldClock: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Audio and video are fed separately, so neither waits on the other's sink.
final class IndependentChainsTests: XCTestCase {
  /// The audio output here takes a fiftieth of a second and never plays, so
  /// it is full almost at once. Video still decodes ahead until its own frame
  /// queue is full.
  ///
  /// With one loop feeding both, video stopped wherever audio did: about one
  /// frame in. Codecs that reorder frames then released them too late for
  /// their time, and they were dropped — the judder seen on real H.264.
  func testVideoDecodesAheadWhileAudioIsHeldUp() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("seek_grid.mp4")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: url),
      audioOutput: VirtualAudioOutput(hostTime: HeldClock(), maxPendingSeconds: 0.02),
      videoRenderer: renderer, hostTime: HeldClock())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()

    var depth = 0
    for _ in 0..<100 {
      depth = await renderer.queueDepth
      if depth >= 3 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(depth, 3, "the video frame queue fills on its own")
  }
}
