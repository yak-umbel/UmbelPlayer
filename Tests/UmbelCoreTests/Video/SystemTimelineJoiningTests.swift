import AVFoundation
import CoreGraphics
import CoreMedia
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

/// A layer the test reads after handing it to a renderer, which sets it on
/// the main thread; the test reads it once that is done.
private struct HeldDisplayLayer: @unchecked Sendable {
  let layer = AVSampleBufferDisplayLayer()
}

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

/// The system's display layer on a session's timeline in place of its own
/// timebase, and back again; and a renderer used for another film after.
final class SystemTimelineJoiningTests: XCTestCase {
  private let host = TimelineHostTime()
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func device() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device here") }
    return device
  }

  func testTheLayerJoinsAndLeaves() async throws {
    let sink = JoiningSink()
    let renderer = try SampleBufferVideoRenderer(sink: sink, device: try device(), tolerance: tolerance)
    let timeline = TimelineDouble(host: host)
    try await renderer.join(timeline)
    XCTAssertTrue(timeline.holds(sink.layer))
    await renderer.leave()
    XCTAssertFalse(timeline.holds(sink.layer))
  }

  /// Used for the next film, it leaves the last one's timeline first —
  /// whether or not that session was stopped.
  func testJoiningAnotherTimelineLeavesTheFirst() async throws {
    let sink = JoiningSink()
    let renderer = try SampleBufferVideoRenderer(sink: sink, device: try device(), tolerance: tolerance)
    let first = TimelineDouble(host: host), second = TimelineDouble(host: host)
    try await renderer.join(first)
    try await renderer.join(second)
    XCTAssertFalse(first.holds(sink.layer))
    XCTAssertTrue(second.holds(sink.layer))
  }

  /// Back on its own timebase, the layer is where the timeline was: that
  /// timebase heard only the clock's commands meanwhile, not the system's
  /// start-up delay, and would put it a fraction of a second off.
  func testLeavingTakesTheTimelinesTime() async throws {
    let renderer = try SampleBufferVideoRenderer(sink: JoiningSink(), device: try device(), tolerance: tolerance)
    let timeline = TimelineDouble(host: host)
    try await renderer.join(timeline)
    timeline.set(rate: 0, time: CMTime(seconds: 12.5, preferredTimescale: 600))
    XCTAssertEqual(CMTimebaseGetTime(renderer.timebase).seconds, 0, accuracy: 1e-6, "not followed meanwhile")
    await renderer.leave()
    XCTAssertEqual(CMTimebaseGetTime(renderer.timebase).seconds, 12.5, accuracy: 1e-3)
  }

  /// Refused, the join is an error with a reason.
  func testARefusedJoinIsAnError() async throws {
    let renderer = try SampleBufferVideoRenderer(sink: JoiningSink(), device: try device(), tolerance: tolerance)
    let timeline = TimelineDouble(host: host)
    timeline.refusesRenderers = true
    do {
      try await renderer.join(timeline)
      XCTFail("a refused join passed")
    } catch UmbelError.videoRenderUnavailable {}
  }

  /// The switching renderer passes it to picture in picture's side.
  func testTheSwitchingRendererPassesItOn() async throws {
    let sink = JoiningSink()
    let pip = try SampleBufferVideoRenderer(sink: sink, device: try device(), tolerance: tolerance)
    let switching = SwitchingVideoRenderer(main: QuietWindow(), pictureInPicture: pip)
    let timeline = TimelineDouble(host: host)
    try await switching.join(timeline)
    XCTAssertTrue(timeline.holds(sink.layer))
    await switching.leave()
    XCTAssertFalse(timeline.holds(sink.layer))
  }

  /// Once joined, how far ahead a compressed picture is goes by the
  /// timeline, not the renderer's own timebase: at 11 s it is within 1.5 s
  /// of the timeline at 10, though its own timebase still stands at 0.
  func testTheLeadIsMeasuredOnTheTimeline() async throws {
    let sink = JoiningSink()
    let renderer = try SampleBufferVideoRenderer(sink: sink, device: try device(), tolerance: tolerance)
    let timeline = TimelineDouble(host: host)
    try await renderer.join(timeline)
    timeline.set(rate: 0, time: CMTime(seconds: 10, preferredTimescale: 600))
    let frame = try compressed(seconds: 11)
    let handing = Task { try await renderer.enqueue(frame) }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(sink.receivedCount, 1)
    handing.cancel()
  }

  /// A picture the system decodes, as `SampleBufferVideoRendererTests` makes one.
  private func compressed(seconds: Double) throws -> VideoFrame {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: nil, codecType: kCMVideoCodecType_DolbyVisionHEVC, width: 64, height: 64,
      extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var size = 4
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReady(
      allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    return VideoFrame(
      presentationTime: time, compressed: try XCTUnwrap(sample), width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt2020, range: .limited, transfer: .pq, primaries: .bt2020),
      isShown: true)
  }

  /// A layer the system will not take — here one another renderer already
  /// put on a timeline, a host's mistake — is an error, not the end of the
  /// process. The system raises an exception for it, and that must be caught
  /// before it unwinds any Swift: inside a task it corrupted the task's
  /// allocator ("freed pointer was not the last allocation").
  func testALayerAlreadyOnATimelineIsAnErrorNotACrash() async throws {
    let held = HeldDisplayLayer()
    let device = try device()
    let one = try SampleBufferVideoRenderer(layer: held.layer, device: device, tolerance: tolerance)
    let other = try SampleBufferVideoRenderer(layer: held.layer, device: device, tolerance: tolerance)
    let first = SynchronizerTimeline(), second = SynchronizerTimeline()
    try await one.join(first)
    do {
      try await other.join(second)
      XCTFail("one layer on two timelines")
    } catch UmbelError.videoRenderUnavailable {}
    await one.leave()
  }

  @MainActor
  func testARealLayerJoinsLeavesAndJoinsAnother() async throws {
    let held = HeldDisplayLayer()
    let layer = held.layer
    let renderer = try SampleBufferVideoRenderer(layer: held.layer, device: try device(), tolerance: tolerance)
    XCTAssertNotNil(layer.controlTimebase, "its own, set when it was made")
    let first = SynchronizerTimeline(), second = SynchronizerTimeline()
    try await renderer.join(first)
    XCTAssertNil(layer.controlTimebase)
    XCTAssertEqual(first.synchronizer.renderers.count, 1)
    try await renderer.join(second)
    XCTAssertEqual(first.synchronizer.renderers.count, 0)
    XCTAssertEqual(second.synchronizer.renderers.count, 1)
    await renderer.leave()
    XCTAssertTrue(layer.controlTimebase === renderer.timebase)
  }
}
