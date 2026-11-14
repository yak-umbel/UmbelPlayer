import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// What the system's display layer is given, and when it is flushed.
private final class LayerRecord: SampleBufferSink, @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [CMSampleBuffer] = []
  private var flushedAt: [Int] = []

  var received: [CMSampleBuffer] { locked { buffers } }
  /// How many buffers had arrived at each flush.
  var flushes: [Int] { locked { flushedAt } }

  func enqueue(_ buffer: CMSampleBuffer) { locked { buffers.append(buffer) } }
  func flush() { locked { flushedAt.append(buffers.count) } }
  var hasFailed: Bool { false }
  var isReadyForMoreMediaData: Bool { true }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

/// The window's side: draws nothing, as it would over the system's picture.
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

/// DV profile 5 played through a session: its packets reach the system's
/// layer as dvh1 samples, and a seek lands without showing earlier frames.
final class DVPlaybackTests: XCTestCase {
  private let layer = LayerRecord()

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func session(showsDV: Bool = true, file: String = "dv_p5.mp4") throws -> PlaybackSession {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device here") }
    let system = try SampleBufferVideoRenderer(
      sink: layer, device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600),
      systemShowsDV: showsDV)
    return PlaybackSession(
      source: try UmbelFileSource(url: fixture(file)), audioOutput: nil,
      videoRenderer: SwitchingVideoRenderer(main: QuietWindow(), pictureInPicture: system),
      hostTime: HeldHost())
  }

  private func shown(_ sample: CMSampleBuffer) -> Bool {
    guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
          CFArrayGetCount(array) > 0 else { return true }
    let first = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSDictionary.self)
    return (first[kCMSampleAttachmentKey_DoNotDisplay] as? Bool) != true
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
  }

  func testP5PlaysThroughTheSystemLayer() async throws {
    let session = try session()
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await waitFor { layer.received.count >= 10 }
    let first = try XCTUnwrap(layer.received.first)
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(first))
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_DolbyVisionHEVC)
    let atoms = CMFormatDescriptionGetExtension(
      description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
      as? [String: Any]
    XCTAssertNotNil(atoms?["dvcC"] as? Data)
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed)
  }

  /// Keyframes every 12 frames at 25 a second: 1.3 s falls between 0.96 and
  /// 1.44. The frames from 0.96 go to the layer for it to decode from, marked
  /// not to be shown; the first shown is at the target or after.
  func testAP5SeekLandsWithoutShowingEarlierFrames() async throws {
    let session = try session()
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    try await waitFor { layer.received.count >= 10 }
    try await session.seek(to: CMTime(seconds: 1.3, preferredTimescale: 600))
    try await waitFor { layer.received.count >= (layer.flushes.last ?? 0) + 10 }
    let flushedAt = try XCTUnwrap(layer.flushes.last, "the layer is cleared on a seek")
    let after = Array(layer.received[flushedAt...])
    let firstShown = try XCTUnwrap(after.firstIndex(where: shown))
    XCTAssertGreaterThan(firstShown, 0, "frames before the target were sent to decode from")
    for sample in after[..<firstShown] {
      XCTAssertLessThan(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 1.3)
    }
    XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(after[firstShown]).seconds, 1.3 - 1e-6)
    for sample in after[firstShown...] where shown(sample) {
      XCTAssertGreaterThanOrEqual(
        CMSampleBufferGetPresentationTimeStamp(sample).seconds, 1.3 - 1e-6, "nothing before the target is shown")
    }
    let now = await session.currentTime.seconds
    XCTAssertEqual(now, 1.3, accuracy: 0.05)
  }

  /// A host that seeks before it plays — to resume where the viewer left
  /// off — gets the picture from there, and playback goes on.
  func testAP5SeekBeforePlayingPlaysOnFromThere() async throws {
    let session = try session()
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 1.3, preferredTimescale: 600))
    try await session.play()
    try await waitFor { layer.received.contains(where: shown) }
    let firstShown = try XCTUnwrap(layer.received.first(where: shown))
    XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(firstShown).seconds, 1.3 - 1e-6)
    let phase = await session.phase
    XCTAssertEqual(phase, .playing)
    let now = await session.currentTime.seconds
    XCTAssertEqual(now, 1.3, accuracy: 0.05)
  }

  /// Parameter sets only at the stream's start, none in its hvcC: a seek
  /// before playing lands on a keyframe without them, and they are found at
  /// the start when the film opens.
  func testParameterSetsAtTheStartServeASeekBeforePlaying() async throws {
    let session = try session(file: "dv_p5_inband.mp4")
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 1.3, preferredTimescale: 600))
    try await session.play()
    try await waitFor { layer.received.contains(where: shown) }
    let firstShown = try XCTUnwrap(layer.received.first(where: shown), "nothing reached the layer")
    XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(firstShown).seconds, 1.3 - 1e-6)
    let phase = await session.phase
    XCTAssertNotEqual(phase, .ended, "not over before it began")
  }

  /// The picture is the system's, yet the session tells when it is up, as it
  /// does for a picture it draws: the system layer's side answers the call.
  func testTheFirstPictureOfP5IsToldFromTheSystemsSide() async throws {
    let session = try session()
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    var picture: PresentedFrame?
    for _ in 0..<300 where picture == nil {
      picture = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let first = try XCTUnwrap(picture, "no picture was told")
    XCTAssertEqual(first.seekGeneration, 0)
    let latched = await session.firstPresentedFrame
    XCTAssertEqual(latched, first)
  }

  /// Paused, the clock stands at the target, between two pictures: the
  /// seek's picture is the first at or after it, and is told all the same.
  func testAPausedP5SeekTellsItsPicture() async throws {
    let session = try session()
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 1.3, preferredTimescale: 600))
    var picture: PresentedFrame?
    for _ in 0..<300 where picture == nil {
      picture = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let first = try XCTUnwrap(picture, "no picture was told while paused")
    XCTAssertEqual(first.seekGeneration, 1)
    XCTAssertGreaterThanOrEqual(first.presentationTime.seconds, 1.3 - 1e-6)
    XCTAssertLessThan(first.presentationTime.seconds, 1.5)
    let latched = await session.firstPresentedFrame
    XCTAssertEqual(latched, first)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
  }

  func testLoadingP5WithoutSupportFails() async throws {
    let session = try session(showsDV: false)
    do {
      try await session.load()
      XCTFail("DV P5 loaded where the system cannot show it")
    } catch UmbelError.unsupportedDynamicHDR(let what) {
      XCTAssertEqual(what, "DV P5")
    }
  }
}
