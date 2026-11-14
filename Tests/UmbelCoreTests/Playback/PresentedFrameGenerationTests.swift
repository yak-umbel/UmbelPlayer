import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class StillHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// A renderer that presents what it is given, can hold a flush to look at a
/// seek half done, and can be made to present a picture of its own, as one
/// left over from before the seek would.
private actor ScriptedRenderer: VideoRenderer {
  private let queue = VideoFrameQueue(capacity: 3, tolerance: CMTime(value: 1, timescale: 50))
  private var holdsFlush = false
  private var heldFlush: CheckedContinuation<Void, Never>?
  private var leftOver: PresentedFrame?

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}

  func enqueue(_ frame: VideoFrame) async throws { await queue.enqueue(frame) }

  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    if let frame = leftOver {
      leftOver = nil
      return frame
    }
    let result = await queue.take(at: time)
    return result.frame.map {
      PresentedFrame(presentationTime: $0.presentationTime, droppedFrames: result.dropped)
    }
  }

  func flush() async {
    if holdsFlush {
      holdsFlush = false
      await withCheckedContinuation { heldFlush = $0 }
    }
    await queue.flush()
  }

  func holdNextFlush() { holdsFlush = true }
  var isHoldingFlush: Bool { heldFlush != nil }
  func releaseFlush() {
    heldFlush?.resume()
    heldFlush = nil
  }
  func presentNext(_ frame: PresentedFrame) { leftOver = frame }

  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { await queue.totalDropped } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// A picture presented says which seek it comes after, and the session
/// keeps the first one since the latest seek: the host asks it whether the
/// seek's picture is up, paused or playing.
final class PresentedFrameGenerationTests: XCTestCase {
  private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

  private func loaded() async throws -> (PlaybackSession, ScriptedRenderer) {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("seek_grid.mp4")
    let renderer = ScriptedRenderer()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: url),
      audioOutput: VirtualAudioOutput(hostTime: StillHostTime(), maxPendingSeconds: 1_000),
      videoRenderer: renderer, hostTime: StillHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    return (session, renderer)
  }

  private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<250 {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting until \(what)")
  }

  private struct NoPicture: Error {}

  /// The next picture the session presents.
  private func nextPicture(_ session: PlaybackSession) async throws -> PresentedFrame {
    for _ in 0..<250 {
      if let frame = try await session.renderVideoFrame() { return frame }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("no picture was presented")
    throw NoPicture()
  }

  func testTheFirstPictureOfASessionIsFromBeforeAnySeek() async throws {
    let (session, _) = try await loaded()
    let before = await session.firstPresentedFrame
    XCTAssertNil(before, "nothing is up before the first picture")

    try await session.play()
    let picture = try await nextPicture(session)

    XCTAssertEqual(picture.seekGeneration, 0)
    let first = await session.firstPresentedFrame
    XCTAssertEqual(first, picture)
    let generation = await session.seekGeneration
    XCTAssertEqual(generation, 0)
  }

  /// Paused, the clock does not run: the picture of the target is told by the
  /// seek it comes after, not by time passing.
  func testAPausedSeekPresentsItsTargetUnderTheNewGeneration() async throws {
    let (session, _) = try await loaded()

    try await session.seek(to: at(5.5))
    let generation = await session.seekGeneration
    XCTAssertEqual(generation, 1)
    let before = await session.firstPresentedFrame
    XCTAssertNil(before, "the picture of the seek is not up yet")

    let picture = try await nextPicture(session)
    XCTAssertEqual(picture.seekGeneration, generation)
    XCTAssertEqual(picture.presentationTime.seconds, 5.5, accuracy: 0.1)
    let first = await session.firstPresentedFrame
    XCTAssertEqual(first, picture)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
  }

  /// What is left of the picture from before the seek, presented while the
  /// seek is under way, says it is from before and is not taken for the
  /// seek's own.
  func testAPictureLeftOverFromBeforeASeekIsNotTakenForOneAfterIt() async throws {
    let (session, renderer) = try await loaded()
    try await session.play()
    _ = try await nextPicture(session)
    await renderer.holdNextFlush()

    let target = at(7.5)
    let seeking = Task { try await session.seek(to: target) }
    await waitUntil("the seek is under way") { await renderer.isHoldingFlush }
    let generation = await session.seekGeneration
    XCTAssertEqual(generation, 1)
    let reset = await session.firstPresentedFrame
    XCTAssertNil(reset, "the seek begins the signal anew")

    await renderer.presentNext(PresentedFrame(presentationTime: at(0.1), droppedFrames: 0))
    let presented = try await session.renderVideoFrame()
    let leftOver = try XCTUnwrap(presented)
    XCTAssertEqual(leftOver.seekGeneration, 0, "it belongs to where playback was")
    let duringSeek = await session.firstPresentedFrame
    XCTAssertNil(duringSeek, "and is not the seek's picture")

    await renderer.releaseFlush()
    try await seeking.value
    let picture = try await nextPicture(session)
    XCTAssertEqual(picture.seekGeneration, 1)
    XCTAssertGreaterThanOrEqual(picture.presentationTime.seconds, 7.5 - 0.1)
    let first = await session.firstPresentedFrame
    XCTAssertEqual(first, picture)
  }

  /// Seeks in a row count up; the picture is of the last.
  func testEachSeekCountsUpAndThePictureIsOfTheLast() async throws {
    let (session, _) = try await loaded()
    try await session.seek(to: at(2.5))
    try await session.seek(to: at(6.5))

    let generation = await session.seekGeneration
    XCTAssertEqual(generation, 2)
    let picture = try await nextPicture(session)
    XCTAssertEqual(picture.seekGeneration, 2)
    XCTAssertEqual(picture.presentationTime.seconds, 6.5, accuracy: 0.1)
  }
}
