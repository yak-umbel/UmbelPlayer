import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class ManualHost: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    defer { lock.unlock() }
    seconds += delta
  }
}

/// A renderer that notes every frame handed to it, as a frame number at 25
/// a second. It holds three, as the real one does, so decoding runs only a
/// little ahead of the clock.
private actor RecordingRenderer: VideoRenderer {
  private let queue = VideoFrameQueue(
    capacity: 3, tolerance: CMTime(value: 1, timescale: 50))
  private(set) var enqueued: [Int] = []

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}

  func enqueue(_ frame: VideoFrame) async throws {
    enqueued.append(Int((frame.presentationTime.seconds * 25).rounded()))
    await queue.enqueue(frame)
  }

  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    let result = await queue.take(at: time)
    return result.frame.map {
      PresentedFrame(presentationTime: $0.presentationTime, droppedFrames: result.dropped)
    }
  }

  func flush() async { await queue.flush() }
  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { await queue.totalDropped } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// Decoding that falls behind the clock skips what it can. b_frames.mkv:
/// four seconds at 25 frames a second, a keyframe every 25 frames, then
/// B B P over and over; the B frames are not referred to. No sound, so the
/// host clock runs the picture.
final class VideoCatchUpTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func isReference(_ frame: Int) -> Bool { frame % 25 % 3 == 0 }

  private func playing() async throws -> (PlaybackSession, ManualHost, RecordingRenderer) {
    let host = ManualHost()
    let renderer = RecordingRenderer()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("b_frames.mkv")), videoRenderer: renderer,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    return (session, host, renderer)
  }

  /// As the display loop goes: a step of time, a frame asked for.
  private func step(
    _ session: PlaybackSession, _ host: ManualHost, times: Int, by seconds: Double = 0.04
  ) async throws {
    for _ in 0..<times {
      host.advance(seconds: seconds)
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  func testTheStepFollowsHowLateTheFrameIs() {
    func step(_ lateness: Double?, _ run: Int) -> VideoCatchUp.Step {
      VideoCatchUp.step(forLateness: lateness, lateInARow: run)
    }
    XCTAssertEqual(step(nil, 0), .decodeAll, "the clock stands still")
    XCTAssertEqual(step(-0.1, 0), .decodeAll)
    XCTAssertEqual(step(0, 0), .decodeAll, "out just in time")
    XCTAssertEqual(step(0.01, 1), .decodeAll, "one late frame is not falling behind")
    XCTAssertEqual(step(0.01, 2), .decodeAll)
    XCTAssertEqual(step(0.01, 3), .skipNonReference)
    XCTAssertEqual(step(0.5, 3), .skipNonReference)
    XCTAssertEqual(step(0.51, 1), .dropToKeyframe, "very late at once")
  }

  func testAFrameInTimeEndsTheLateRun() {
    XCTAssertEqual(VideoCatchUp.lateRun(after: 2, lateness: 0.1), 3)
    XCTAssertEqual(VideoCatchUp.lateRun(after: 5, lateness: -0.01), 0)
    XCTAssertEqual(VideoCatchUp.lateRun(after: 5, lateness: 0), 0)
    XCTAssertEqual(VideoCatchUp.lateRun(after: 5, lateness: nil), 0, "the clock stands still")
  }

  /// A seek ends the run: two late frames before it and one after are not
  /// three in a row.
  func testASeekEndsTheLateRun() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("b_frames.mkv")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    addTeardownBlock { await session.close() }

    let host = ManualHost()
    let clock = PresentationClock(hostTime: host)
    await clock.setRate(1)
    host.advance(seconds: 1)
    let catchUp = VideoCatchUp(
      cache: PacketCache(configuration: .init(), measuredTrack: nil), clock: clock)
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 16, cb: 128, cr: 128))
    let late = VideoFrame(
      presentationTime: CMTime(seconds: 0.9, preferredTimescale: 600), pixelBuffer: buffer,
      width: 16, height: 16, color: VideoColorDescription(matrix: .bt709, range: .limited))

    await catchUp.review([late], from: session, track: video.id)
    await catchUp.review([late], from: session, track: video.id)
    await catchUp.reset()
    await catchUp.review([late], from: session, track: video.id)
    let skipping = await session.skipsNonReference
    XCTAssertFalse(skipping)
  }

  /// Keeping up, nothing is skipped.
  func testOnTimeEveryFrameIsDecoded() async throws {
    let (session, host, renderer) = try await playing()
    try await step(session, host, times: 110)
    let enqueued = await renderer.enqueued
    XCTAssertEqual(enqueued, Array(0..<100))
  }

  /// The clock jumps 0.45 s ahead of decoding — as though frames had taken
  /// that long. Until decoding is back in time, the frames nothing refers
  /// to are left out; every other frame still decodes.
  func testLateDecodingSkipsTheFramesNothingRefersTo() async throws {
    let (session, host, renderer) = try await playing()
    try await step(session, host, times: 10)
    host.advance(seconds: 0.45)
    try await step(session, host, times: 1, by: 0)
    try await Task.sleep(nanoseconds: 50_000_000)
    try await step(session, host, times: 30)

    // Frames already with the decoder's threads when it fell behind decode
    // regardless, so where the skipped ones start depends on the core count.
    let enqueued = await renderer.enqueued
    XCTAssertEqual(Array(enqueued.prefix(11)), Array(0...10), "in time, every frame")
    let reached = try XCTUnwrap(enqueued.last)
    XCTAssertGreaterThan(reached, 45)
    let missing = (11...reached).filter { !enqueued.contains($0) }
    XCTAssertFalse(missing.isEmpty, "late, some frames were left out")
    XCTAssertEqual(missing.filter(isReference), [], "only frames nothing refers to")
    XCTAssertEqual(
      Array(enqueued.suffix(10)), Array(reached - 9...reached), "in time again, every frame")
  }

  /// Behind, then paused: the clock waits for decoding, which catches up
  /// without skipping anything.
  func testNothingIsSkippedWhileTheClockStandsStill() async throws {
    let (session, host, renderer) = try await playing()
    try await step(session, host, times: 10)
    host.advance(seconds: 0.45)
    await session.pause()
    try await step(session, host, times: 10, by: 0)
    try await session.play()
    try await step(session, host, times: 20)

    let enqueued = await renderer.enqueued
    let reached = try XCTUnwrap(enqueued.last)
    XCTAssertGreaterThan(reached, 40)
    XCTAssertEqual(enqueued, Array(0...reached))
  }

  /// The clock jumps two seconds ahead: decoding starts again from the
  /// keyframe at 2 s instead of working through every frame before it.
  func testVeryLateDecodingStartsAgainFromAKeyframe() async throws {
    let (session, host, renderer) = try await playing()
    try await step(session, host, times: 10)
    host.advance(seconds: 2.0)
    var shown: [Double] = []
    for _ in 0..<3 {
      if let frame = try await session.renderVideoFrame() {
        shown.append(frame.presentationTime.seconds)
      }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    XCTAssertGreaterThanOrEqual(shown.last ?? 0, 2.0, "showing from the keyframe on")
    let enqueued = await renderer.enqueued
    // Late from about frame 14 on: after it, nothing until the keyframe — not
    // even the frames already with the decoder's threads.
    XCTAssertEqual(enqueued.filter { $0 > 15 && $0 < 50 }, [], "never decoded")
    XCTAssertTrue(enqueued.contains(50), "the keyframe")
  }
}
