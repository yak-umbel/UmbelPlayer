import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class WeakVideoSurface {
  weak var value: CVPixelBuffer?
  init(_ value: CVPixelBuffer) { self.value = value }
}

/// Holds frames as a real renderer does — `capacity` of them, the next
/// waiting — and records what reaches it.
private actor RecordingRenderer: VideoRenderer, ClockFollower {
  private let queue: VideoFrameQueue
  private(set) var received: [Double] = []
  private(set) var flushes = 0
  private(set) var subtitles: [[UmbelSubtitleBitmap]] = []
  private(set) var presented = 0
  /// Each turn into or out of the subtitle overlay, in order.
  private(set) var overlays: [Bool] = []
  private let heard = Heard()
  private let showsDV: Bool

  init(capacity: Int = 3, showsDV: Bool = false) {
    queue = VideoFrameQueue(capacity: capacity, tolerance: CMTime(value: 1, timescale: 50))
    self.showsDV = showsDV
  }

  func setOverlaysSystemPicture(_ overlays: Bool) async { self.overlays.append(overlays) }
  /// Each step aside for picture in picture, and back, in order.
  private(set) var asides: [Bool] = []
  func stepAside(_ aside: Bool) async { asides.append(aside) }
  var showsSystemDecodedDV: Bool { showsDV }

  var clockChanges: Int { heard.count }

  nonisolated func clockDidChange(anchor: RenderAnchor, rate: Double) { heard.add() }

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}

  func enqueue(_ frame: VideoFrame) async throws {
    await queue.enqueue(frame)
    received.append(frame.presentationTime.seconds)
  }

  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    presented += 1
    guard let frame = await queue.take(at: time).frame else { return nil }
    return PresentedFrame(presentationTime: frame.presentationTime, droppedFrames: 0)
  }

  func flush() async {
    flushes += 1
    await queue.flush()
    // Decoding waiting for room takes it the moment there is some.
    if let fill = fillOnFlush { await queue.enqueue(fill) }
  }

  /// Filled up with `frame` each time it is flushed, as by decoding that
  /// was waiting for room and got it first.
  private var fillOnFlush: VideoFrame?
  func fillUpOnFlush(with frame: VideoFrame) { fillOnFlush = frame }

  /// The pictures handed over apart from the queue, in order.
  private(set) var seeded: [Double] = []
  func seed(_ frame: VideoFrame) async {
    seeded.append(frame.presentationTime.seconds)
    await queue.seed(frame)
  }

  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async { subtitles.append(bitmaps) }
  private(set) var geometry: (aspectRatio: Double?, scaling: UmbelPictureScaling)?
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {
    geometry = (aspectRatio, scaling)
  }
}

extension RecordingRenderer: SystemPictureOverlay, SystemDecodedVideoShowing, PictureSteppingAside, FrameSeeding {}

/// A renderer of a host's: queues frames, and knows nothing of handing one
/// over apart from its queue.
private actor PlainRenderer: VideoRenderer {
  private let queue = VideoFrameQueue(capacity: 1, tolerance: CMTime(value: 1, timescale: 50))
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws { await queue.enqueue(frame) }
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    guard let frame = await queue.take(at: time).frame else { return nil }
    return PresentedFrame(presentationTime: frame.presentationTime, droppedFrames: 0)
  }
  func flush() async { await queue.flush() }
  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// Whether `operation` finishes within `seconds`.
private func finishes(within seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask { await operation(); return true }
    group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return false }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
  }
}

private final class Heard: @unchecked Sendable {
  private let lock = NSLock()
  private var changes = 0
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return changes
  }
  func add() {
    lock.lock()
    changes += 1
    lock.unlock()
  }
}

/// Two renderers, one shown at a time — the window's and picture in
/// picture's — swapped while playing.
final class SwitchingVideoRendererTests: XCTestCase {
  private func frame(_ seconds: Double) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 126, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      pixelBuffer: buffer, width: 16, height: 16,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  private func subtitle() -> UmbelSubtitleBitmap {
    let context = CGContext(
      data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    return UmbelSubtitleBitmap(image: context.makeImage()!, frame: CGRect(x: 0, y: 0, width: 2, height: 2))
  }

  func testFramesGoToTheActiveRendererOnly() async throws {
    let main = RecordingRenderer()
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(frame(1))
    _ = try await switching.presentFrame(at: .zero)
    await switching.show(.pictureInPicture)
    try await switching.enqueue(frame(2))
    _ = try await switching.presentFrame(at: .zero)
    let mainFrames = await main.received
    let pipFrames = await pip.received
    let carried = await pip.seeded
    XCTAssertEqual(mainFrames, [1])
    XCTAssertEqual(carried, [1], "the picture showing, carried over apart from the queue")
    XCTAssertEqual(pipFrames, [2], "then the next")
    let mainPresented = await main.presented
    let pipPresented = await pip.presented
    XCTAssertEqual([mainPresented, pipPresented], [1, 1])
    let shown = await switching.active
    XCTAssertEqual(shown, .pictureInPicture)
  }

  /// Subtitles already showing come along: the layout asks again only when
  /// the canvas changes size, and the two may well be the same size.
  /// The window's renderer steps aside while its picture is in picture in
  /// picture, and back when it returns: see `PictureSteppingAside`.
  func testTheWindowStepsAsideWhileThePictureIsAway() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(frame(0))
    await switching.show(.pictureInPicture)
    var asides = await main.asides
    XCTAssertEqual(asides, [true])
    await switching.show(.main)
    asides = await main.asides
    XCTAssertEqual(asides, [true, false])
    let pipAsides = await pip.asides
    XCTAssertEqual(pipAsides, [])
  }

  /// The system's picture is on its layer for both: nothing steps aside.
  func testNothingStepsAsideWhileTheSystemShowsThePicture() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    await switching.show(.pictureInPicture)
    await switching.show(.main)
    let asides = await main.asides
    XCTAssertEqual(asides, [])
  }

  /// Paused, a switch completes however full the arriving side is: decoding
  /// can fill it the moment it is flushed, and paused, nothing takes from
  /// it. Queued behind that, the picture showing waited for good. It is
  /// handed over apart from the queue, and shown next.
  func testAPausedSwitchCompletesWhenTheArrivingSideIsFull() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer(capacity: 1)
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(frame(0))
    _ = try await switching.presentFrame(at: .zero)
    await pip.fillUpOnFlush(with: frame(0.08))
    let switched = await finishes(within: 2) { await switching.show(.pictureInPicture) }
    XCTAssertTrue(switched, "the switch returned")
    guard switched else { return await pip.flush() }
    let shown = try await switching.presentFrame(at: .zero)
    XCTAssertEqual(shown?.presentationTime.seconds, 0, "the picture that was showing, the clock unmoved")
  }

  /// Back and forth, paused, each side full: every switch returns, and the
  /// picture showing stays the one it was.
  func testPausedSwitchesBackAndForthAllComplete() async throws {
    let main = RecordingRenderer(capacity: 1), pip = RecordingRenderer(capacity: 1)
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(frame(0))
    _ = try await switching.presentFrame(at: .zero)
    await main.fillUpOnFlush(with: frame(0.08))
    await pip.fillUpOnFlush(with: frame(0.08))
    for output in [SwitchingVideoRenderer.Output.pictureInPicture, .main, .pictureInPicture, .main] {
      let switched = await finishes(within: 2) { await switching.show(output) }
      XCTAssertTrue(switched, "to \(output)")
      guard switched else { return }
      let shown = try await switching.presentFrame(at: .zero)
      XCTAssertEqual(shown?.presentationTime.seconds, 0, "to \(output)")
    }
  }

  /// A host's renderer, which cannot take a picture apart from its queue,
  /// does not hold the switch either.
  func testASwitchToAHostsFullRendererDoesNotWait() async throws {
    let main = RecordingRenderer(), plain = PlainRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: plain)
    try await switching.enqueue(frame(0))
    _ = try await switching.presentFrame(at: .zero)
    try await plain.enqueue(frame(0.08))
    let switched = await finishes(within: 2) { await switching.show(.pictureInPicture) }
    XCTAssertTrue(switched)
    await plain.flush()
  }

  func testSwitchingResendsTheSubtitles() async throws {
    let main = RecordingRenderer()
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    await switching.setSubtitles([subtitle()])
    await switching.show(.pictureInPicture)
    let given = await pip.subtitles
    XCTAssertEqual(given.map(\.count), [1])
  }

  /// Decoding waiting on a full queue when the switch comes: the frame it
  /// holds goes to the renderer now shown, not to the one left.
  func testAFrameWaitingOnTheOldRendererGoesToTheNew() async throws {
    let main = RecordingRenderer(capacity: 1)
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(frame(1))
    let second = frame(2)
    let waiting = Task { try await switching.enqueue(second) }
    try await Task.sleep(nanoseconds: 50_000_000)
    await switching.show(.pictureInPicture)
    try await waiting.value
    let pipFrames = await pip.received
    XCTAssertEqual(pipFrames, [2])
  }

  /// Both follow the clock all along: picture in picture can start at any
  /// moment with its timebase already right.
  func testBothHearTheClock() async {
    let main = RecordingRenderer()
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    let clock = PresentationClock(hostTime: SystemHostTimeSource(), follower: switching)
    await clock.setRate(1)
    let heard = await [main.clockChanges, pip.clockChanges]
    XCTAssertEqual(heard, [1, 1])
  }

  /// The picture showing goes along, so the one arriving has it at once —
  /// paused too, when no new frame will come. The system opens picture in
  /// picture from what its layer shows; from nothing, it fails.
  func testThePictureShowingGoesAlong() async throws {
    let main = RecordingRenderer()
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(frame(1))
    try await switching.enqueue(frame(2))
    _ = try await switching.presentFrame(at: CMTime(seconds: 1, preferredTimescale: 600))
    await switching.show(.pictureInPicture)
    let given = await pip.seeded
    XCTAssertEqual(given, [1])
    var shown = await switching.hasPresentedSinceSwitch
    XCTAssertFalse(shown)
    let again = try await switching.presentFrame(at: CMTime(seconds: 1, preferredTimescale: 600))
    XCTAssertEqual(again?.presentationTime.seconds ?? -1, 1, accuracy: 1e-6)
    shown = await switching.hasPresentedSinceSwitch
    XCTAssertTrue(shown)
  }

  // ── The system showing the picture (DV profile 5) ───────

  private func compressed(_ seconds: Double) throws -> VideoFrame {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: nil, codecType: kCMVideoCodecType_DolbyVisionHEVC, width: 16, height: 16,
      extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: 1, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: 1, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    let time = CMTime(seconds: seconds, preferredTimescale: 600)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var size = 1
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReady(
      allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    return VideoFrame(
      presentationTime: time, compressed: try XCTUnwrap(sample), width: 16, height: 16,
      color: VideoColorDescription(matrix: .bt2020, range: .limited, transfer: .pq, primaries: .bt2020),
      isShown: true)
  }

  func testACompressedFrameTurnsTheWindowIntoTheSubtitleOverlay() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    let overlays = await main.overlays
    let mainFrames = await main.received
    let pipFrames = await pip.received
    XCTAssertEqual(overlays, [true])
    XCTAssertEqual(mainFrames, [], "the window draws no picture now")
    XCTAssertEqual(pipFrames, [0], "the picture goes to the system's layer")
  }

  func testSystemPixelsAreNotRetainedBySwitchingWhenTheHostStopsDrawing() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    func handOn() async throws -> WeakVideoSurface {
      var picture = frame(0)
      picture.presentationRoute = .systemPixels
      let weak = WeakVideoSurface(try XCTUnwrap(picture.pixelBuffer))
      try await switching.enqueue(picture)
      await pip.flush() // The system finished using the surface without a host display tick.
      return weak
    }
    let surface = try await handOn()
    XCTAssertNil(surface.value, "system output never needs to carry a pixel to the other renderer")
  }

  func testSubtitlesGoToTheOverlayWhileTheSystemShowsThePicture() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    await switching.setSubtitles([])
    let mainSubtitles = await main.subtitles.count
    let pipSubtitles = await pip.subtitles.count
    XCTAssertGreaterThan(mainSubtitles, 0)
    XCTAssertEqual(pipSubtitles, 0)
  }

  func testPresentingDrawsTheOverlayAndReportsTheSystemsPicture() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    let presented = try await switching.presentFrame(at: .zero)
    let mainPresented = await main.presented
    XCTAssertEqual(mainPresented, 1, "the overlay had its turn")
    XCTAssertEqual(presented?.presentationTime.seconds, 0)
  }

  /// The picture is on the system's layer already: opening picture in
  /// picture moves nothing, and nothing is flushed.
  func testPictureInPictureNeedsNoSwitchWhileTheSystemShowsThePicture() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    await switching.show(.pictureInPicture)
    let mainFlushes = await main.flushes
    let pipFlushes = await pip.flushes
    let presentedSince = await switching.hasPresentedSinceSwitch
    XCTAssertEqual(mainFlushes, 0)
    XCTAssertEqual(pipFlushes, 0)
    XCTAssertTrue(presentedSince, "the layer shows a picture already")
    try await switching.enqueue(try compressed(0.04))
    let pipFrames = await pip.received
    XCTAssertEqual(pipFrames, [0, 0.04])
  }

  /// The system's picture gone to picture in picture, the window's overlay
  /// is left with subtitles over a placeholder: it is cleared, and has them
  /// again when the picture comes back. Picture in picture cannot show them
  /// over the system's picture either.
  func testTheOverlayIsClearedWhileThePictureIsInPictureInPicture() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    let line = [subtitle()]
    await switching.setSubtitles(line)
    await switching.show(.pictureInPicture)
    var mainSubtitles = await main.subtitles
    XCTAssertEqual(mainSubtitles.last?.count, 0, "cleared in the window")
    await switching.setSubtitles(line)
    mainSubtitles = await main.subtitles
    XCTAssertEqual(mainSubtitles.last?.count, 0, "and kept clear while the picture is away")
    let pipSubtitles = await pip.subtitles
    XCTAssertEqual(pipSubtitles.count, 0, "none to the system's layer either")
    await switching.show(.main)
    mainSubtitles = await main.subtitles
    XCTAssertEqual(mainSubtitles.last?.count, 1, "back with the picture")
  }

  func testADecodedFrameEndsTheOverlay() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    try await switching.enqueue(frame(1))
    let overlays = await main.overlays
    let mainFrames = await main.received
    XCTAssertEqual(overlays, [true, false])
    XCTAssertEqual(mainFrames, [1])
  }

  /// Back to pictures drawn here — an inserted run encoded otherwise — the
  /// system's last picture goes from its layer.
  func testLeavingTheSystemsPictureClearsItsLayer() async throws {
    let main = RecordingRenderer(), pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    try await switching.enqueue(try compressed(0))
    try await switching.enqueue(frame(1))
    let pipFlushes = await pip.flushes
    XCTAssertEqual(pipFlushes, 1)
  }

  func testItAsksThePictureInPictureSideWhetherTheSystemShowsDV() async {
    let yes = SwitchingVideoRenderer(main: RecordingRenderer(), pictureInPicture: RecordingRenderer(showsDV: true))
    let no = SwitchingVideoRenderer(main: RecordingRenderer(), pictureInPicture: RecordingRenderer(showsDV: false))
    let a = await yes.showsSystemDecodedDV
    let b = await no.showsSystemDecodedDV
    XCTAssertTrue(a)
    XCTAssertFalse(b)
  }

  func testFlushClearsBoth() async {
    let main = RecordingRenderer()
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    await switching.flush()
    let flushes = await [main.flushes, pip.flushes]
    XCTAssertEqual(flushes, [1, 1])
  }

  /// Both sides lay the picture out alike: either may take over at once.
  func testTheGeometryGoesToBoth() async {
    let main = RecordingRenderer()
    let pip = RecordingRenderer()
    let switching = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    await switching.setPictureGeometry(aspectRatio: 2, scaling: .fill)
    let onMain = await main.geometry
    let onPip = await pip.geometry
    XCTAssertEqual(onMain?.aspectRatio, 2)
    XCTAssertEqual(onMain?.scaling, .fill)
    XCTAssertEqual(onPip?.aspectRatio, 2)
    XCTAssertEqual(onPip?.scaling, .fill)
  }
}
