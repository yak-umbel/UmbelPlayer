import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// The window's side: draws nothing.
private actor QuietWindow: VideoRenderer {
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { get async { .zero } }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// A session with the sample buffer output: its clock is the system's
/// timeline, picture in picture's layer is on it from loading to stopping,
/// and seeking, pausing and the rate are set on it.
final class SystemTimelinePlaybackTests: XCTestCase {
  private let host = TimelineHostTime()
  private lazy var timeline = TimelineDouble(host: host)
  private let maker = RendererMaker()
  private let sink = JoiningSink()

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func renderer() throws -> SwitchingVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device here") }
    let pip = try SampleBufferVideoRenderer(
      sink: sink, device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    return SwitchingVideoRenderer(main: QuietWindow(), pictureInPicture: pip)
  }

  private func session(
    renderer: SwitchingVideoRenderer, timeline: TimelineDouble? = nil
  ) throws -> PlaybackSession {
    let output = SampleBufferAudioOutput(timeline: timeline ?? self.timeline) { [maker] in maker.make($0) }
    return PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")), audioOutput: output,
      videoRenderer: renderer, hostTime: host)
  }

  private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<300 where !(await condition()) { try await Task.sleep(nanoseconds: 10_000_000) }
  }

  func testTheLayerIsOnTheTimelineFromLoadingToStopping() async throws {
    let session = try session(renderer: try renderer())
    try await session.load()
    XCTAssertTrue(timeline.holds(sink.layer))
    let authority = await session.clockAuthority
    XCTAssertEqual(authority, .system)
    await session.stop()
    XCTAssertFalse(timeline.holds(sink.layer))
  }

  /// Playing, seeking and the rate reach the timeline; the time is its.
  func testPlayingSeekingAndTheRateAreSetOnTheTimeline() async throws {
    let session = try session(renderer: try renderer())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await waitUntil { self.timeline.rateOnlySets.last == 1 }
    XCTAssertEqual(timeline.rateOnlySets.last, 1)
    try await session.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
    XCTAssertTrue(timeline.sets.contains { $0.time == 3 })
    await session.setRate(2)
    try await waitUntil { self.timeline.rateOnlySets.last == 2 }
    XCTAssertEqual(timeline.rateOnlySets.last, 2)
    host.advance(seconds: 1)
    let now = await session.currentTime.seconds
    XCTAssertEqual(now, timeline.time.seconds, accuracy: 1e-6)
  }

  /// Sound off and on while playing: the time stays the system's, and the
  /// frames reach the renderer again.
  func testSoundOffAndOnKeepsTheTimeline() async throws {
    let session = try session(renderer: try renderer())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    let selected = await session.selectedAudioTrack
    let audio = try XCTUnwrap(selected)
    try await session.selectAudioTrack(nil)
    let authority = await session.clockAuthority
    XCTAssertEqual(authority, .system)
    try await session.selectAudioTrack(audio)
    let rendererNow = try XCTUnwrap(maker.made.last)
    try await waitUntil { !rendererNow.holding.isEmpty }
    XCTAssertFalse(rendererNow.holding.isEmpty)
  }

  /// The same picture in picture renderer for the next film: on the new
  /// session's timeline, off the last one's.
  func testTwoSessionsInTurnWithOneRenderer() async throws {
    let renderer = try renderer()
    let firstTimeline = TimelineDouble(host: host), secondTimeline = TimelineDouble(host: host)
    let first = try session(renderer: renderer, timeline: firstTimeline)
    try await first.load()
    await first.stop()
    let second = try session(renderer: renderer, timeline: secondTimeline)
    try await second.load()
    addTeardownBlock { await second.stop() }
    XCTAssertFalse(firstTimeline.holds(sink.layer))
    XCTAssertTrue(secondTimeline.holds(sink.layer))
  }
}
