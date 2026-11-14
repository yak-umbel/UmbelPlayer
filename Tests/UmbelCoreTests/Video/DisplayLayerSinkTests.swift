import AVFoundation
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// Observes the adapter's calls without depending on asynchronous decoding.
private final class DisplayLayerCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  private var offMain = false

  func record(_ event: String) {
    lock.withLock {
      events.append(event)
      offMain = offMain || !Thread.isMainThread
    }
  }

  var recorded: [String] { lock.withLock { events } }
  var usedBackgroundThread: Bool { lock.withLock { offMain } }
}

private final class ObservedDisplayLayer: AVSampleBufferDisplayLayer {
  nonisolated let calls = DisplayLayerCalls()
  private var failed = true

  override func enqueue(_ sampleBuffer: CMSampleBuffer) {
    calls.record("enqueue \(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)")
  }

  override func flushAndRemoveImage() {
    calls.record("flush")
    failed = false
  }

  override var status: AVQueuedSampleBufferRenderingStatus {
    calls.record("status")
    return failed ? .failed : .unknown
  }

  override var isReadyForMoreMediaData: Bool {
    calls.record("ready")
    return !failed
  }

  @available(macOS 14, iOS 17, tvOS 17, *)
  override var sampleBufferRenderer: AVSampleBufferVideoRenderer {
    calls.record("renderer")
    return super.sampleBufferRenderer
  }

  override var controlTimebase: CMTimebase? {
    get { super.controlTimebase }
    set {
      calls.record("timebase")
      super.controlTimebase = newValue
    }
  }
}

/// Shared only to exercise synchronous entry from a background caller.
/// The adapter must perform every layer access on the main actor.
private final class DisplayLayerReference: @unchecked Sendable {
  let layer: ObservedDisplayLayer
  @MainActor init() { layer = ObservedDisplayLayer() }
}

@MainActor
final class DisplayLayerSinkTests: XCTestCase {
  /// The old-system adapter is exercised even on systems with a renderer.
  /// Deferring enqueue would let a completion escape the epoch's flush gate.
  func testLegacySubmissionFinishesOnMainAndCannotOutliveFlush() async throws {
    let layer = ObservedDisplayLayer()
    let sink = LegacyDisplayLayerSink(layer: layer)
    let calls = layer.calls
    try await Task.detached {
      // Named, not `Self`: in a detached task `Self` would carry the test case along.
      let first = try DisplayLayerSinkTests.sample(seconds: 1)
      let next = try DisplayLayerSinkTests.sample(seconds: 2)
      let epoch = VideoSubmissionEpoch()
      let old = epoch.value
      epoch.withCurrent(old) { sink.enqueue(first) }
      XCTAssertEqual(calls.recorded, ["enqueue 1.0"], "enqueue must finish before returning")
      epoch.advance()
      sink.flush()
      XCTAssertEqual(calls.recorded, ["enqueue 1.0", "flush"], "flush must finish before returning")
      epoch.withCurrent(old) { sink.enqueue(first) }
      epoch.withCurrent(epoch.value) { sink.enqueue(next) }
      XCTAssertEqual(calls.recorded, ["enqueue 1.0", "flush", "enqueue 2.0"])
    }.value
    XCTAssertFalse(calls.usedBackgroundThread)
  }

  func testLegacyStateReadsFollowFlushAndCallsAlsoWorkOnMain() async throws {
    let layer = ObservedDisplayLayer()
    let sink = LegacyDisplayLayerSink(layer: layer)
    await Task.detached {
      XCTAssertTrue(sink.hasFailed)
      XCTAssertFalse(sink.isReadyForMoreMediaData)
      sink.flush()
      XCTAssertFalse(sink.hasFailed)
      XCTAssertTrue(sink.isReadyForMoreMediaData)
    }.value
    sink.enqueue(try Self.sample(seconds: 3))
    sink.flush()
    XCTAssertFalse(layer.calls.usedBackgroundThread)
    XCTAssertEqual(layer.calls.recorded.suffix(2), ["enqueue 3.0", "flush"])
  }

  func testModernRendererIsAcquiredOnceOnMainForBackgroundUse() async throws {
    guard #available(macOS 14, iOS 17, tvOS 17, *) else { throw XCTSkip("requires a separate video renderer") }
    let reference = DisplayLayerReference()
    try await Task.detached {
      let sink = DisplayLayerSink(layer: reference.layer)
      _ = sink.isReadyForMoreMediaData
      _ = sink.hasFailed
      sink.enqueue(try DisplayLayerSinkTests.sample(seconds: 0))
      sink.flush()
    }.value
    XCTAssertEqual(reference.layer.calls.recorded, ["renderer"])
    XCTAssertFalse(reference.layer.calls.usedBackgroundThread)
  }

  func testSynchronousPublicInitializerConfiguresLayerOnMainFromBackground() async throws {
    let reference = DisplayLayerReference()
    let renderer = try await Task.detached {
      let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
      return try SampleBufferVideoRenderer(
        layer: reference.layer, device: device, tolerance: CMTime(value: 1, timescale: 50))
    }.value
    XCTAssertTrue(reference.layer.controlTimebase === renderer.timebase)
    XCTAssertTrue(reference.layer.calls.recorded.contains("timebase"))
    XCTAssertFalse(reference.layer.calls.usedBackgroundThread)
  }

  nonisolated private static func sample(seconds: Double) throws -> CMSampleBuffer {
    let pixels = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 128, cb: 128, cr: 128))
    return try VideoSampleBuffer.make(
      of: pixels, at: CMTime(seconds: seconds, preferredTimescale: 600), immediately: false)
  }
}
