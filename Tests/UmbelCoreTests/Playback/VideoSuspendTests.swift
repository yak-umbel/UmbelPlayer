import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

/// Notes the times of the frames it is given; shows each at once.
private actor FrameRecord: VideoRenderer {
  private(set) var times: [Double] = []
  private var queued: [VideoFrame] = []
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {
    times.append(frame.presentationTime.seconds)
    queued.append(frame)
  }
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    guard let due = queued.last(where: { $0.presentationTime <= time }) else { return nil }
    queued.removeAll { $0.presentationTime <= time }
    return PresentedFrame(presentationTime: due.presentationTime, droppedFrames: 0)
  }
  func flush() async { queued.removeAll() }
  var queueDepth: Int { get async { queued.count } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { get async { .zero } }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// A host sent to the background with nothing showing the picture stops
/// its decoding; sound plays on, and the picture comes back after.
final class VideoSuspendTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// Played in real time, the display loop driven here.
  private func playing(_ renderer: FrameRecord) async throws -> (PlaybackSession, Task<Void, Never>) {
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")), videoRenderer: renderer)
    try await session.load()
    try await session.play()
    let loop = Task {
      while !Task.isCancelled {
        _ = try? await session.renderVideoFrame()
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }
    return (session, loop)
  }

  func testNoFramesAreDecodedWhileSuspended() async throws {
    let renderer = FrameRecord()
    let (session, loop) = try await playing(renderer)
    defer { loop.cancel() }
    addTeardownBlock { await session.stop() }
    try await Task.sleep(nanoseconds: 800_000_000)
    await session.setVideoSuspended(true)
    try await Task.sleep(nanoseconds: 200_000_000)
    let before = await renderer.times.count
    let clockBefore = await session.currentTime.seconds
    try await Task.sleep(nanoseconds: 800_000_000)
    let after = await renderer.times.count
    let clockAfter = await session.currentTime.seconds
    XCTAssertEqual(after, before, "nothing decoded meanwhile")
    XCTAssertGreaterThan(clockAfter - clockBefore, 0.5, "playback goes on")
  }

  /// Resumed, the picture is back from where playback is, not from where
  /// it stopped.
  func testThePictureComesBackFromWherePlaybackIs() async throws {
    let renderer = FrameRecord()
    let (session, loop) = try await playing(renderer)
    defer { loop.cancel() }
    addTeardownBlock { await session.stop() }
    try await Task.sleep(nanoseconds: 500_000_000)
    await session.setVideoSuspended(true)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let seen = await renderer.times.count
    let now = await session.currentTime.seconds
    await session.setVideoSuspended(false)
    for _ in 0..<200 where await renderer.times.count <= seen {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let times = await renderer.times
    XCTAssertGreaterThan(times.count, seen, "frames again")
    let shownAfter = times[seen...].max() ?? 0
    XCTAssertGreaterThanOrEqual(shownAfter, now - 0.1, "from where playback is")
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed)
  }
}
