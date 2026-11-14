import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// A line still on screen long after it began must come back when its track
/// is turned off and on again while paused, without moving the playhead.
final class LongLineReselectTests: XCTestCase {
  private final class HeldClock: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// The picture is black, so bright pixels are the line.
  private func brightPixels(_ session: PlaybackSession) async throws -> Int {
    let image = try await session.snapshot()
    let bytes = [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
    // Step by step: one expression of this size takes the older compiler too long.
    let threshold = 3 * 160
    var count = 0
    var offset = 0
    while offset + 3 < bytes.count {
      let red = Int(bytes[offset])
      let green = Int(bytes[offset + 1])
      let blue = Int(bytes[offset + 2])
      if red + green + blue > threshold { count += 1 }
      offset += 4
    }
    return count
  }

  private func waitForLine(_ session: PlaybackSession, shown: Bool) async throws -> Bool {
    for _ in 0..<100 {
      if (try await brightPixels(session) > 0) == shown { return true }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
  }

  func testALongLineReturnsWhenReselectedWhilePaused() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("long_movtext.mp4")),
      videoRenderer: renderer, hostTime: HeldClock())
    try await session.load()
    addTeardownBlock { await session.stop() }
    let tracks = await session.tracks
    let line = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    try await session.selectSubtitleTrack(line.id)
    // The line began at 1 s: 9.9 s back is still within reach of the seek,
    // and reading on from there passes ten seconds after it began.
    try await session.seek(to: CMTime(seconds: 10.9, preferredTimescale: 600))
    var presented = false
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { presented = true; break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(presented)
    await session.pause()
    let first = try await waitForLine(session, shown: true)
    XCTAssertTrue(first, "the line shows after the seek")

    try await session.selectSubtitleTrack(nil)
    let off = try await waitForLine(session, shown: false)
    XCTAssertTrue(off, "turning the track off clears the line")
    try await session.selectSubtitleTrack(line.id)
    let back = try await waitForLine(session, shown: true)
    XCTAssertTrue(back, "the line still showing comes back with its track")

    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
    let time = await session.currentTime.seconds
    XCTAssertEqual(time, 10.9, accuracy: 0.05, "reselecting does not move the playhead")
  }
}
