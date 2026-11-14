import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import UmbelCore

/// A layer the test reads after handing it to a renderer, which sets it on
/// the main thread; the test reads it once that is done.
private struct HeldLayer: @unchecked Sendable {
  let layer: CAMetalLayer
}

private final class CountingDrawableLayer: CAMetalLayer, @unchecked Sendable {
  private let lock = NSLock()
  private var requests = 0
  private var returnedDrawable = false
  var cancelOnRequest = false

  var requestCount: Int { lock.withLock { requests } }
  var suppliedDrawable: Bool { lock.withLock { returnedDrawable } }

  override func nextDrawable() -> (any CAMetalDrawable)? {
    lock.withLock { requests += 1 }
    if cancelOnRequest { withUnsafeCurrentTask { $0?.cancel() } }
    let drawable = super.nextDrawable()
    if drawable != nil { lock.withLock { returnedDrawable = true } }
    return drawable
  }
}

private struct HeldCountingLayer: @unchecked Sendable {
  let layer: CountingDrawableLayer
}

final class MetalVideoRendererTests: XCTestCase {
  private func makeRendererOrSkip(drawableSize: CGSize = CGSize(width: 64, height: 64))
    throws -> MetalVideoRenderer
  {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let pipeline = try MetalPipeline(device: device)
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.drawableSize = drawableSize
    return MetalVideoRenderer(
      pipeline: pipeline, layer: layer, capacity: 3,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
  }

  private func frame(seconds: Double) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(
      width: 64, height: 64, luma: 128, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      pixelBuffer: buffer, width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  /// Over a picture the system shows (DV profile 5): the layer turns
  /// see-through and draws no frames; back out, it is opaque again.
  func testTheOverlayIsSeeThroughAndDrawsNoFrames() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let held = HeldLayer(layer: CAMetalLayer())
    held.layer.device = device
    held.layer.drawableSize = CGSize(width: 64, height: 64)
    let renderer = MetalVideoRenderer(
      pipeline: try MetalPipeline(device: device), layer: held.layer, capacity: 3,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    try await prepared(renderer)
    await renderer.setOverlaysSystemPicture(true)
    XCTAssertFalse(held.layer.isOpaque)
    try await renderer.enqueue(frame(seconds: 0))
    let presented = try await renderer.presentFrame(at: .zero)
    XCTAssertNil(presented, "the picture is the system's")
    await renderer.setOverlaysSystemPicture(false)
    XCTAssertTrue(held.layer.isOpaque)
  }

  /// The picture gone to picture in picture, the window shows nothing of its
  /// own: see-through, its last picture gone. Showing the picture from when
  /// the small window opened, it covered the one coming back from it. Back,
  /// it is opaque again.
  func testSteppingAsideLeavesNothingShowing() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let held = HeldLayer(layer: CAMetalLayer())
    held.layer.device = device
    held.layer.drawableSize = CGSize(width: 64, height: 64)
    let renderer = MetalVideoRenderer(
      pipeline: try MetalPipeline(device: device), layer: held.layer, capacity: 3,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    try await prepared(renderer)
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    await renderer.stepAside(true)
    XCTAssertFalse(held.layer.isOpaque)
    let kept = await renderer.snapshotFrame
    XCTAssertNil(kept, "the last picture is gone")
    await renderer.stepAside(false)
    XCTAssertTrue(held.layer.isOpaque)
  }

  /// Over the system's picture the layer is cleared to nothing, so the
  /// picture beneath shows around the subtitles; a picture of its own is on
  /// black. Cleared opaque, the overlay would hide the system's picture.
  func testTheOverlayIsClearedToNothingAPictureToBlack() {
    XCTAssertEqual(MetalVideoRenderer.overlayClear.alpha, 0)
    XCTAssertEqual(MetalVideoRenderer.pictureClear.alpha, 1)
    XCTAssertEqual(MetalVideoRenderer.pictureClear.red, 0)
  }

  private func prepared(_ renderer: MetalVideoRenderer) async throws {
    try await renderer.prepare(
      width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  func testPresentsFrameWhoseTimeHasArrived() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    try await renderer.enqueue(frame(seconds: 0))
    let presented = try await renderer.presentFrame(at: .zero)
    XCTAssertEqual(presented?.presentationTime.seconds, 0)
  }

  func testReturnsNilWhenHeadIsInFuture() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    // Present a frame first — "keep showing the last frame" needs a last
    // frame. Without one, the head is drawn however far off; see
    // VideoFrameQueue.
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)

    try await renderer.enqueue(frame(seconds: 5))
    let presented = try await renderer.presentFrame(at: .zero)
    XCTAssertNil(presented, "nothing is presented while the head is still in the future")
  }

  func testReportsDroppedFrames() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    for index in 0..<3 {
      try await renderer.enqueue(frame(seconds: Double(index) * 0.04))
    }
    let presented = try await renderer.presentFrame(
      at: CMTime(seconds: 0.08, preferredTimescale: 600))
    XCTAssertEqual(presented?.droppedFrames, 2)
  }

  func testFlushEmptiesQueue() async throws {
    let renderer = try makeRendererOrSkip()
    try await prepared(renderer)
    try await renderer.enqueue(frame(seconds: 0))
    await renderer.flush()
    let depth = await renderer.queueDepth
    XCTAssertEqual(depth, 0)
  }

  /// No drawable (a layer of zero size, a window not on screen) is not a
  /// crash but a round not drawn — the display loop comes dozens of times a
  /// second, and missing one now and then is normal.
  func testMissingDrawableIsNotFatal() async throws {
    let renderer = try makeRendererOrSkip(drawableSize: .zero)
    try await prepared(renderer)
    try await renderer.enqueue(frame(seconds: 0))
    // Not throwing and not crashing is enough.
    _ = try await renderer.presentFrame(at: .zero)
  }

  func testCancelledRenderNeverRequestsDrawable() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let held = HeldCountingLayer(layer: CountingDrawableLayer())
    held.layer.device = device
    held.layer.drawableSize = CGSize(width: 64, height: 64)
    let renderer = MetalVideoRenderer(
      pipeline: try MetalPipeline(device: device), layer: held.layer,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    try await prepared(renderer)
    try await renderer.enqueue(frame(seconds: 0))

    let request = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await renderer.presentFrame(at: .zero)
    }
    do {
      _ = try await request.value
      XCTFail("cancelled render was accepted")
    } catch is CancellationError {}
    XCTAssertEqual(held.layer.requestCount, 0)
  }

  func testCancellationAfterDrawableAcquisitionDoesNotSubmit() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let held = HeldCountingLayer(layer: CountingDrawableLayer())
    held.layer.device = device
    held.layer.drawableSize = CGSize(width: 64, height: 64)
    held.layer.cancelOnRequest = true
    let renderer = MetalVideoRenderer(
      pipeline: try MetalPipeline(device: device), layer: held.layer,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    try await prepared(renderer)
    try await renderer.enqueue(frame(seconds: 0))

    let request = Task { try await renderer.presentFrame(at: .zero) }
    do {
      _ = try await request.value
      XCTFail("render continued after drawable acquisition cancelled it")
    } catch is CancellationError {}
    XCTAssertEqual(held.layer.requestCount, 1)
    guard held.layer.suppliedDrawable else {
      throw XCTSkip("offscreen layer supplied no drawable")
    }
  }
}
