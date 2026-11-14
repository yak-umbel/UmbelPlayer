import CoreGraphics
import CoreMedia
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

/// Records what a display layer would be given.
private final class RecordingSink: SampleBufferSink, @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [CMSampleBuffer] = []
  private var flushes = 0
  private var failed = false
  private var ready = true

  /// Whether the layer takes more now: a full one holds the next back.
  var isReadyForMoreMediaData: Bool {
    lock.lock()
    defer { lock.unlock() }
    return ready
  }

  func setReady(_ value: Bool) {
    lock.lock()
    ready = value
    lock.unlock()
  }

  var received: [CMSampleBuffer] {
    lock.lock()
    defer { lock.unlock() }
    return buffers
  }

  var flushCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return flushes
  }

  func fail() {
    lock.lock()
    failed = true
    lock.unlock()
  }

  var hasFailed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return failed
  }

  func enqueue(_ buffer: CMSampleBuffer) {
    lock.lock()
    buffers.append(buffer)
    lock.unlock()
  }

  func flush() {
    lock.lock()
    flushes += 1
    failed = false
    lock.unlock()
  }

  private var fills: [Bool] = []
  var fillsAsked: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return fills
  }

  func setFillsView(_ fills: Bool) {
    lock.lock()
    self.fills.append(fills)
    lock.unlock()
  }
}

/// Frames drawn with their subtitles into buffers for the system's sample
/// buffer display layer — the picture in picture window's content — timed
/// by a timebase that follows the clock.
final class SampleBufferVideoRendererTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
  private let sink = RecordingSink()

  func testTenBitCompositeRetainsHighPrecisionInStandardRange() async throws {
    let renderer = try await renderer()
    let buffer = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(width: 64, height: 64, luma: 500, cb: 512, cr: 512))
    try await renderer.enqueue(VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
      color: .init(matrix: .bt709, range: .limited)))
    _ = try await renderer.presentFrame(at: .zero)
    for _ in 0..<100 {
      if !sink.received.isEmpty { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(try XCTUnwrap(sink.received.first)))
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_64RGBAHalf)
    let transfer = CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
    XCTAssertEqual(transfer, kCVImageBufferTransferFunction_Linear as String)
  }

  func testCompositeUsesRequestedPixelSizeWithoutReducingPrecision() async throws {
    let renderer = try await renderer()
    await renderer.setRenderSize(CGSize(width: 32, height: 32))
    let buffer = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(width: 64, height: 36, luma: 700, cb: 512, cr: 512))
    try await renderer.enqueue(VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 36,
      color: .init(matrix: .bt709, range: .limited)))
    _ = try await renderer.presentFrame(at: .zero)
    let samples = try await waitFor(1)
    let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(samples[0]))
    XCTAssertEqual(CVPixelBufferGetWidth(output), 32)
    XCTAssertEqual(CVPixelBufferGetHeight(output), 18)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_64RGBAHalf)
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 32, height: 18))
    let source = await renderer.snapshotFrame
    XCTAssertTrue(source?.pixelBuffer === buffer)
    XCTAssertEqual(source?.width, 64)
    XCTAssertEqual(source?.height, 36)
  }

  func testPausedCompositeRedrawsAtANewPixelSize() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    _ = try await waitFor(1)
    await renderer.setRenderSize(CGSize(width: 32, height: 32))
    _ = try await renderer.presentFrame(at: .zero)
    let samples = try await waitFor(2)
    let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(samples[1]))
    XCTAssertEqual(CVPixelBufferGetWidth(output), 32)
    XCTAssertEqual(CVPixelBufferGetHeight(output), 32)
  }

  func testACompositePixelLimitDoesNotEnlargeTheSource() async throws {
    let renderer = try await renderer()
    await renderer.setRenderSize(CGSize(width: 128, height: 128))
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    let samples = try await waitFor(1)
    let output = try XCTUnwrap(CMSampleBufferGetImageBuffer(samples[0]))
    XCTAssertEqual(CVPixelBufferGetWidth(output), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(output), 64)
  }

  func testSystemPixelsKeepTheirOriginalBufferAndAttachments() async throws {
    let renderer = try await renderer()
    await renderer.setRenderSize(CGSize(width: 16, height: 16))
    let buffer = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(
      width: 64, height: 64, luma: 721, cb: 512, cr: 512))
    // A sentinel proves attachment transport, not native dynamic metadata effects.
    let key = "UmbelTransportSentinel" as CFString
    CVBufferSetAttachment(buffer, key, "preserved" as CFString, .shouldPropagate)
    var picture = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
      color: .init(matrix: .bt2020, range: .limited, transfer: .hlg, primaries: .bt2020))
    picture.presentationRoute = .systemPixels
    try await renderer.enqueue(picture)
    _ = try await renderer.presentFrame(at: .zero)
    let sample = try XCTUnwrap(sink.received.first)
    XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === buffer)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))),
                   kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    let capabilities = await renderer.videoCapabilities
    XCTAssertEqual(capabilities.snapshot, .unsupported(.systemDisplay))
  }

  private func renderer() async throws -> SampleBufferVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let renderer = try SampleBufferVideoRenderer(sink: sink, device: device, tolerance: tolerance)
    try await renderer.prepare(
      width: 64, height: 64, color: VideoColorDescription(matrix: .bt709, range: .limited))
    return renderer
  }

  /// Grey is luma 126 in limited range: about 128 out.
  private func frame(luma: UInt8 = 126, seconds: Double) -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: luma, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      pixelBuffer: buffer, width: 64, height: 64,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  /// A white block over the lower middle, as bitmap subtitles come.
  private func whiteBlock() throws -> UmbelSubtitleBitmap {
    var bytes = [UInt8]()
    for _ in 0..<8 { bytes += [255, 255, 255, 255] }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return UmbelSubtitleBitmap(image: image, frame: CGRect(x: 16, y: 40, width: 32, height: 16))
  }

  /// The GPU finishes after presenting returns: buffers arrive shortly.
  private func waitFor(_ count: Int) async throws -> [CMSampleBuffer] {
    for _ in 0..<200 {
      if sink.received.count >= count { return sink.received }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("\(count) buffers did not arrive; \(sink.received.count) did")
    return sink.received
  }

  /// Green of a pixel of a BGRA buffer.
  private func green(_ buffer: CMSampleBuffer, x: Int, y: Int) throws -> Int {
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
    return Int(base[y * CVPixelBufferGetBytesPerRow(image) + x * 4 + 1])
  }

  private func displaysImmediately(_ buffer: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
            as? [[CFString: Any]] else { return false }
    return attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true
  }

  func testADueFrameGoesOutWithItsTime() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(frame(seconds: 1))
    let presented = try await renderer.presentFrame(at: CMTime(seconds: 1, preferredTimescale: 600))
    XCTAssertEqual(presented?.presentationTime.seconds ?? -1, 1, accuracy: 1e-6)
    let buffers = try await waitFor(1)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffers[0]).seconds, 1, accuracy: 1e-6)
    XCTAssertFalse(displaysImmediately(buffers[0]))
  }

  /// Picture in picture is drawn into a buffer of the turned shape, and a
  /// redraw while paused — a subtitle changing — keeps both shape and turn.
  func testATurnedFrameIsDrawnTurnedAndRedrawnTurned() async throws {
    let renderer = try await renderer()
    let color = VideoColorDescription(matrix: .bt709, range: .limited)
    let buffer = VideoFrame.makeSplitPixelBuffer(width: 128, height: 64, orientation: .topLeftBright)!
    try await renderer.enqueue(VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 128, height: 64, color: color,
      rotation: .clockwise90))
    _ = try await renderer.presentFrame(at: .zero)
    let first = try await waitFor(1)[0]
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(first))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 128)
    XCTAssertGreaterThan(try green(first, x: 48, y: 32), 200, "top-right is bright")
    XCTAssertLessThan(try green(first, x: 16, y: 32), 60)
    XCTAssertLessThan(try green(first, x: 48, y: 96), 60)
    XCTAssertLessThan(try green(first, x: 16, y: 96), 60)

    await renderer.setSubtitles([])
    _ = try await renderer.presentFrame(at: CMTime(seconds: 1, preferredTimescale: 600))
    let again = try await waitFor(2)[1]
    let redrawn = try XCTUnwrap(CMSampleBufferGetImageBuffer(again))
    XCTAssertEqual(CVPixelBufferGetWidth(redrawn), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(redrawn), 128)
    XCTAssertGreaterThan(try green(again, x: 48, y: 32), 200, "still turned when drawn again")
  }

  /// The picture and its subtitles, drawn as the window draws them.
  func testThePixelsAreTheFramesWithItsSubtitles() async throws {
    let renderer = try await renderer()
    await renderer.setSubtitles([try whiteBlock()])
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    let buffer = try await waitFor(1)[0]
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffer))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 64)
    XCTAssertEqual(try green(buffer, x: 32, y: 10), 128, accuracy: 4, "the grey picture")
    XCTAssertEqual(try green(buffer, x: 32, y: 48), 255, accuracy: 4, "the white subtitle")
  }

  /// Paused, a subtitle that appears still has to show: the last picture is
  /// drawn again with it, marked to be shown at once.
  func testNewSubtitlesWhilePausedRedrawAtOnce() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    _ = try await waitFor(1)
    await renderer.setSubtitles([try whiteBlock()])
    let again = try await renderer.presentFrame(at: .zero)
    XCTAssertNil(again, "no new frame was due")
    let buffers = try await waitFor(2)
    XCTAssertTrue(displaysImmediately(buffers[1]))
    XCTAssertEqual(try green(buffers[1], x: 32, y: 48), 255, accuracy: 4)
  }

  func testFlushClearsTheLayerToo() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(frame(seconds: 0))
    await renderer.flush()
    XCTAssertEqual(sink.flushCount, 1)
    let depth = await renderer.queueDepth
    XCTAssertEqual(depth, 0)
  }

  /// A layer the system gave up on — after the window went off screen, say
  /// — is cleared and fed again rather than left blank.
  func testAFailedLayerIsClearedAndGoesOn() async throws {
    let renderer = try await renderer()
    sink.fail()
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    _ = try await waitFor(1)
    XCTAssertEqual(sink.flushCount, 1)
  }

  // ── Pictures the system decodes (DV profile 5) ─────────

  private func compressed(seconds: Double, shown: Bool = true) throws -> VideoFrame {
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
      isShown: shown)
  }

  /// Drawn at the shape asked for: a square picture at 2:1 comes out twice
  /// as wide — what picture in picture shows.
  func testAnAspectRatioDrawsThePictureAtThatShape() async throws {
    let renderer = try await renderer()
    await renderer.setPictureGeometry(aspectRatio: 2, scaling: .fit)
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    let buffers = try await waitFor(1)
    let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(buffers[0]))
    XCTAssertEqual(CVPixelBufferGetWidth(image), 128)
    XCTAssertEqual(CVPixelBufferGetHeight(image), 64)
  }

  /// The layer fills the view only when the system shows the picture in the
  /// window; drawn pictures go to picture in picture, which shows them whole.
  func testFillingReachesTheLayerOnlyForPicturesTheSystemShows() async throws {
    let renderer = try await renderer()
    await renderer.setPictureGeometry(aspectRatio: nil, scaling: .fill)
    try await renderer.enqueue(frame(seconds: 0))
    _ = try await renderer.presentFrame(at: .zero)
    _ = try await waitFor(1)
    XCTAssertEqual(sink.fillsAsked, [], "a drawn picture: the layer left as it is")
    try await renderer.enqueue(compressed(seconds: 0.04))
    XCTAssertEqual(sink.fillsAsked, [true])
    try await renderer.enqueue(compressed(seconds: 0.08))
    XCTAssertEqual(sink.fillsAsked, [true], "asked once, not on every sample")
  }

  /// In the order given — decode order — and as given, not drawn again.
  func testCompressedFramesGoOutUntouchedInTheOrderGiven() async throws {
    let renderer = try await renderer()
    let frames = try [0.0, 0.08, 0.04].map { try compressed(seconds: $0) }
    for frame in frames { try await renderer.enqueue(frame) }
    let received = sink.received
    XCTAssertEqual(received.count, 3)
    for (buffer, frame) in zip(received, frames) {
      XCTAssertTrue(buffer === frame.compressedSample, "the very sample, untouched")
    }
  }

  func testAFullLayerHoldsTheNextFrameBack() async throws {
    let renderer = try await renderer()
    sink.setReady(false)
    let frame = try compressed(seconds: 0)
    let waiting = Task { try await renderer.enqueue(frame) }
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(sink.received.count, 0, "held back while the layer is full")
    sink.setReady(true)
    try await waiting.value
    XCTAssertEqual(sink.received.count, 1)
  }

  func testSystemPixelsRespectSurfaceCapacityEvenWhenTheLayerKeepsAccepting() async throws {
    let renderer = try await renderer()
    for seconds in [0.04, 0.08, 0.12] {
      var picture = frame(seconds: seconds)
      picture.presentationRoute = .systemPixels
      try await renderer.enqueue(picture)
    }
    var fourth = frame(seconds: 0.16)
    fourth.presentationRoute = .systemPixels
    let waiting = Task { try await renderer.enqueue(fourth) }
    try await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(sink.received.count, 3, "decoded surfaces are bounded independently of compressed lead")
    renderer.clockDidChange(anchor: RenderAnchor(mediaTime: CMTime(value: 1, timescale: 25),
      hostTime: CMClockGetTime(CMClockGetHostTimeClock())), rate: 0)
    try await waiting.value
    XCTAssertEqual(sink.received.count, 4, "a due surface makes room without requiring a host render tick")
  }

  /// The layer takes nearly all it is given: a frame far ahead of the
  /// picture showing waits, or a whole film would be read into it at once.
  func testAFrameFarAheadWaitsForThePictureToCatchUp() async throws {
    let renderer = try await renderer()
    let far = try compressed(seconds: 5)
    let waiting = Task { try await renderer.enqueue(far) }
    try await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(sink.received.count, 0, "5 s ahead of a picture at 0")
    renderer.clockDidChange(
      anchor: RenderAnchor(mediaTime: CMTime(seconds: 4, preferredTimescale: 600), hostTime: CMClockGetTime(CMClockGetHostTimeClock())),
      rate: 0)
    try await waiting.value
    XCTAssertEqual(sink.received.count, 1, "within reach once the picture is at 4 s")
  }

  func testFramesBehindThePictureGoAtOnce() async throws {
    let renderer = try await renderer()
    renderer.clockDidChange(
      anchor: RenderAnchor(mediaTime: CMTime(seconds: 10, preferredTimescale: 600), hostTime: CMClockGetTime(CMClockGetHostTimeClock())),
      rate: 0)
    try await renderer.enqueue(try compressed(seconds: 9.5, shown: false))
    XCTAssertEqual(sink.received.count, 1, "before a seek's target: decoded from, sent at once")
  }

  func testAFlushDropsTheFrameWaitingForRoom() async throws {
    let renderer = try await renderer()
    sink.setReady(false)
    let frame = try compressed(seconds: 0)
    let waiting = Task { try await renderer.enqueue(frame) }
    try await Task.sleep(nanoseconds: 20_000_000)
    await renderer.flush()
    sink.setReady(true)
    try await waiting.value
    XCTAssertEqual(sink.received.count, 0, "it belonged to before the seek")
  }

  func testPresentingReportsTheLatestSampleDueWithoutDrawing() async throws {
    let renderer = try await renderer()
    for seconds in [0.0, 0.04, 0.08] { try await renderer.enqueue(try compressed(seconds: seconds)) }
    let presented = try await renderer.presentFrame(at: CMTime(seconds: 0.05, preferredTimescale: 600))
    XCTAssertEqual(presented?.presentationTime.seconds ?? -1, 0.04, accuracy: 1e-6)
    let depth = await renderer.queueDepth
    XCTAssertEqual(depth, 1, "the one at 0.08 is still to come")
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(sink.received.count, 3, "nothing drawn: only the three samples reached the layer")
  }

  func testHiddenSamplesAreNeverReportedShown() async throws {
    let renderer = try await renderer()
    try await renderer.enqueue(try compressed(seconds: 0, shown: false))
    let presented = try await renderer.presentFrame(at: CMTime(seconds: 1, preferredTimescale: 600))
    XCTAssertNil(presented)
    XCTAssertEqual(sink.received.count, 1, "sent all the same: the system decodes from it")
  }

  /// The system could not take these: an error, not a picture frozen in silence.
  func testAFailedLayerIsReportedAsAnError() async throws {
    let renderer = try await renderer()
    sink.fail()
    do {
      try await renderer.enqueue(try compressed(seconds: 0))
      XCTFail("a failed layer went unreported")
    } catch UmbelError.videoRenderUnavailable {
    }
  }

  func testWhetherTheSystemShowsDVIsAsked() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let can = try SampleBufferVideoRenderer(sink: sink, device: device, tolerance: tolerance, systemShowsDV: true)
    let cannot = try SampleBufferVideoRenderer(sink: sink, device: device, tolerance: tolerance, systemShowsDV: false)
    let yes = await can.showsSystemDecodedDV
    let no = await cannot.showsSystemDecodedDV
    XCTAssertTrue(yes)
    XCTAssertFalse(no)
  }

  func testP81PixelsAreOfferedWhereTheSystemDecodesDV() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    for dv in [true, false] {
      let renderer = try SampleBufferVideoRenderer(sink: sink, device: device, tolerance: tolerance, systemShowsDV: dv)
      let shows = await renderer.showsP81SystemPixels
      #if targetEnvironment(simulator)
      XCTAssertFalse(shows)
      #else
      XCTAssertEqual(shows, dv, "systemShowsDV \(dv)")
      #endif
    }
  }

  func testTheTimebaseKeepsWithTheClockForCompressedFrames() async throws {
    let renderer = try await renderer()
    let clock = PresentationClock(hostTime: SystemHostTimeSource(), follower: renderer)
    await clock.reset(to: CMTime(seconds: 5, preferredTimescale: 600))
    try await renderer.enqueue(try compressed(seconds: 5))
    for rate in [1.0, 0.5, 0.0] {
      await clock.setRate(rate)
      try await Task.sleep(nanoseconds: 50_000_000)
      let now = await clock.now().seconds
      XCTAssertEqual(CMTimebaseGetTime(renderer.timebase).seconds, now, accuracy: 0.002, "at \(rate)×")
    }
  }

  /// The layer's timebase follows the clock: read at any moment, the two
  /// agree to within two milliseconds, at any rate.
  func testTheTimebaseKeepsWithTheClock() async throws {
    let renderer = try await renderer()
    let clock = PresentationClock(hostTime: SystemHostTimeSource(), follower: renderer)
    await clock.setRate(1)
    await clock.reset(to: CMTime(seconds: 5, preferredTimescale: 600))
    for rate in [1.0, 2.0, 0.5, 0.0] {
      await clock.setRate(rate)
      try await Task.sleep(nanoseconds: 50_000_000)
      let now = await clock.now().seconds
      let shown = CMTimebaseGetTime(renderer.timebase).seconds
      XCTAssertEqual(shown, now, accuracy: 0.002, "at \(rate)×")
    }
  }
}
