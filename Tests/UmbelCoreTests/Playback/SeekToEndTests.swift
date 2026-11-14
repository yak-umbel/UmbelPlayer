import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// A seek to the very end — where a scrubber is let go at its right edge —
/// shows the last picture, not whatever was on screen before the seek.
final class SeekToEndTests: XCTestCase {
  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
  }

  private func picture(at seconds: Double) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 126, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: time(seconds), pixelBuffer: buffer, width: 16, height: 16,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  func testTheLastPictureBeforeTheTargetShowsWhenContentEndsFirst() {
    var gate = DiscardGate()
    gate.armBoth(at: time(30))
    XCTAssertTrue(gate.videoFramesToDeliver([picture(at: 29.9)]).isEmpty)
    let atEnd = gate.videoFramesAtEnd([picture(at: 29.96)])
    XCTAssertEqual(atEnd.map { $0.presentationTime.seconds }, [29.96], "the last picture, once")
    XCTAssertFalse(gate.hidesVideo(at: time(29)), "the seek is over")
  }

  func testTheEndChangesNothingOnceTheTargetWasReached() {
    var gate = DiscardGate()
    gate.armBoth(at: time(10))
    _ = gate.videoFramesToDeliver([picture(at: 9.9)])
    _ = gate.videoFramesToDeliver([picture(at: 10.0)])
    let atEnd = gate.videoFramesAtEnd([picture(at: 10.05)])
    XCTAssertEqual(atEnd.map { $0.presentationTime.seconds }, [10.05])
  }

  func testANewSeekForgetsThePictureHeldForTheLastOne() {
    var gate = DiscardGate()
    gate.armBoth(at: time(30))
    _ = gate.videoFramesToDeliver([picture(at: 29.9)])
    gate.armBoth(at: time(5))
    XCTAssertTrue(gate.videoFramesAtEnd([]).isEmpty, "a picture from before the new seek is not shown")
  }

  /// seek_grid.mp4: 30 s at 30 frames a second, white only for the first
  /// tenth of each second. At 3.0 s it is white; its last frame is dark.
  func testSeekingToTheEndShowsTheLastPicture() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("seek_grid.mp4")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: url), videoRenderer: renderer, hostTime: HeldHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }

    try await session.seek(to: time(3.0))
    var shown: PresentedFrame?
    for _ in 0..<100 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    let bright = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertGreaterThan(Int(bright.r), 180, "white at 3.0 s, before seeking to the end")

    let duration = await session.duration
    try await session.seek(to: duration)
    var last: PresentedFrame?
    for _ in 0..<100 where last == nil {
      last = try await session.renderVideoFrame()
      if last == nil { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    let frame = try XCTUnwrap(last, "a picture is shown at the end")
    XCTAssertGreaterThan(frame.presentationTime.seconds, 29.5)
    XCTAssertLessThan(frame.presentationTime.seconds, duration.seconds)
    let dark = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertLessThan(Int(dark.r), 100, "the last picture is dark; white is the one from before the seek")
    let capabilities = await session.videoCapabilities
    XCTAssertEqual(capabilities.snapshot, .available, "what is on screen can be captured")
  }
}
