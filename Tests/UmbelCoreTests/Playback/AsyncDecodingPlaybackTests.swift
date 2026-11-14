import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class AsyncModeClock: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds = 0.0
  var now: CMTime {
    lock.lock(); defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }
  func advance(_ delta: Double) { lock.lock(); seconds += delta; lock.unlock() }
}

private actor RecordingVideoRenderer: VideoRenderer {
  private(set) var times: [CMTime] = []
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws { times.append(frame.presentationTime) }
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async { times = [] }
  var queueDepth: Int { 0 }
  var totalDroppedFrames: Int { 0 }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

final class AsyncDecodingPlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }
  private func make(
    mode: UmbelVideoDecodingMode, clock: AsyncModeClock = AsyncModeClock()
  ) async throws -> (PlaybackSession, OffscreenVideoRenderer) {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")),
      videoRenderer: renderer, hostTime: clock, videoDecodingMode: mode)
    addTeardownBlock { await session.stop() }
    try await session.load()
    return (session, renderer)
  }
  private func show(_ session: PlaybackSession) async throws -> PresentedFrame {
    for _ in 0..<200 {
      if let frame = try await session.renderVideoFrame() { return frame }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw UmbelError.videoRenderUnavailable(reason: "no decoded picture")
  }

  func testDefaultIsSynchronousAndInactiveWithoutVideoOutput() async throws {
    let session = PlaybackSession(source: try UmbelFileSource(url: fixture("sync_check.mp4")))
    addTeardownBlock { await session.stop() }
    let before = await session.videoDecodingStatus
    let requested = await session.videoDecodingMode
    XCTAssertEqual(before, .inactive)
    XCTAssertEqual(requested, .synchronous)
    try await session.load()
    let loaded = await session.videoDecodingStatus
    XCTAssertEqual(loaded, .inactive)
  }

  func testBothModesRenderAndSeekWhilePausedWithMatchingPixels() async throws {
    var snapshots: [Data] = []
    for mode in [UmbelVideoDecodingMode.synchronous, .asynchronous] {
      let (session, _) = try await make(mode: mode)
      let status = await session.videoDecodingStatus
      XCTAssertEqual(status, mode == .synchronous ? .synchronous : .asynchronous)
      for (time, minimum, maximum) in [(2.5, 0, 30), (1.0, 220, 255), (3.5, 0, 30)] {
        try await session.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        let frame = try await show(session)
        XCTAssertEqual(frame.presentationTime.seconds, time, accuracy: 0.04)
        let snapshot = try await session.snapshot()
        let bytes = try XCTUnwrap(snapshot.dataProvider?.data) as Data
        let pixel = Int(bytes[100 * snapshot.bytesPerRow + 160 * 4])
        XCTAssertGreaterThanOrEqual(pixel, minimum)
        XCTAssertLessThanOrEqual(pixel, maximum)
        if mode == .synchronous { snapshots.append(bytes) }
        else { XCTAssertEqual(bytes, snapshots.removeFirst()) }
        let phase = await session.phase
        XCTAssertEqual(phase, .paused)
      }
      await session.stop()
      let stopped = await session.videoDecodingStatus
      XCTAssertEqual(stopped, .inactive)
    }
  }

  func testAsyncStopReleasesFullRendererAndKeepsNoFailure() async throws {
    let (session, renderer) = try await make(mode: .asynchronous)
    try await session.play()
    for _ in 0..<200 {
      if await renderer.queueDepth == 3 { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let depth = await renderer.queueDepth
    XCTAssertEqual(depth, 3)
    await session.stop()
    let phase = await session.phase
    let failure = await session.failureReason
    let stoppedDepth = await renderer.queueDepth
    XCTAssertEqual(phase, .idle)
    XCTAssertNil(failure)
    XCTAssertEqual(stoppedDepth, 0)
  }

  func testAsyncSeekDuringPlaybackKeepsPlayingIntent() async throws {
    let (session, _) = try await make(mode: .asynchronous)
    try await session.play()
    _ = try await show(session)
    try await session.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600))
    let frame = try await show(session)
    XCTAssertEqual(frame.presentationTime.seconds, 2.5, accuracy: 0.04)
    for _ in 0..<200 {
      if await session.phase == .playing { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .playing)
  }
  func testAsyncDrainsEveryFrameBeforeEndingAtItsFullDuration() async throws {
    let clock = AsyncModeClock()
    let renderer = RecordingVideoRenderer()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")),
      videoRenderer: renderer, hostTime: clock, videoDecodingMode: .asynchronous)
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    for _ in 0..<400 {
      if await renderer.times.count == 180 { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let times = await renderer.times.map(\.seconds)
    XCTAssertEqual(times.count, 180)
    for (index, time) in times.enumerated() {
      XCTAssertEqual(time, Double(index) / 30, accuracy: 0.0001)
    }
    let before = await session.phase
    XCTAssertEqual(before, .playing)
    clock.advance(6)
    for _ in 0..<200 {
      if await session.phase == .ended { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let ended = await session.phase
    let end = await session.currentTime
    XCTAssertEqual(ended, .ended)
    XCTAssertEqual(end.seconds, 6, accuracy: 0.0001)
    let finalCount = await renderer.times.count
    XCTAssertEqual(finalCount, 180)
  }

  func testAsyncSuspendAndRenewUnderBackpressureResumesAtCurrentPosition() async throws {
    let clock = AsyncModeClock()
    let (session, renderer) = try await make(mode: .asynchronous, clock: clock)
    try await session.play()
    for _ in 0..<200 {
      if await renderer.queueDepth == 3 { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let full = await renderer.queueDepth
    XCTAssertEqual(full, 3)
    await session.setVideoSuspended(true)
    let suspended = await session.videoDecodingStatus
    XCTAssertEqual(suspended, .asynchronous)
    let empty = await renderer.queueDepth
    XCTAssertEqual(empty, 0, "suspension releases queued and waiting old frames")
    clock.advance(2.5)
    await session.setVideoSuspended(false)
    let frame = try await show(session)
    XCTAssertEqual(frame.presentationTime.seconds, 2.5, accuracy: 0.04)
    let failure = await session.failureReason
    XCTAssertNil(failure)
    let status = await session.videoDecodingStatus
    XCTAssertEqual(status, .asynchronous)
  }

}
