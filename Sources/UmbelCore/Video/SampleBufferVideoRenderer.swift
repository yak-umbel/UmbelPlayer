import AVFoundation
import CoreMedia
import CoreVideo
import Metal

/// Draws pictures and subtitles to the system's sample buffer display layer.
/// The host calls `presentFrame(at:)`; there is no display loop here.
/// The layer follows the playback clock, or joins the session's system timeline.
///
/// Composite HDR maps to SDR with independently selected precision. A render
/// size limit bounds the composite surface; original system samples and their
/// metadata bypass composition.
public actor SampleBufferVideoRenderer: VideoRenderer, ClockFollower, VideoDiagnosticsReceiving {
  private let pipeline: MetalPipeline
  private let sink: any SampleBufferSink
  private let queue: VideoFrameQueue
  private let pixelCapacity: Int
  /// The layer's control timebase, set from the clock on each change.
  internal nonisolated let timebase: CMTimebase
  /// The picture as shown: stored pixels at their shape. The canvas.
  private var pictureSize = CGSize.zero
  private var renderSize = CompositeRenderSize()
  private var subtitles = SubtitleOverlay()
  /// Drawn again when the subtitles change and no new frame is due.
  private var lastFrame: VideoFrame?
  private var needsRedraw = false
  private var adjustments = UmbelVideoAdjustments()
  private var pool = DrawingBufferPool()
  private var highPrecisionRejected = false
  /// Whether the system here can show DV without a base layer of its own.
  private let systemShowsDV: Bool
  /// Times of the compressed samples sent to be shown, not yet reported:
  /// the system shows them itself, by the timebase.
  private var systemShown: [CMTime] = []
  /// Whether a sample the system shows has been reported since the last flush.
  private var hasReportedSystemSample = false
  /// Up by one on each flush: a sample waiting for room across one belongs
  /// to before it.
  private var generation = 0
  private let submissionEpoch = VideoSubmissionEpoch()
  /// The session's system timeline its layer is on, when there is one.
  private var joined: (any SystemTimeline)?
  /// The host's shape and scaling for the picture.
  private var geometry = PictureGeometry.standard
  /// Whether the layer was last told to fill the view; nil before it was.
  private var fillsView: Bool?
  private var systemVideoRoute = false
  private var observation: VideoPresentationObservation?
  private var observationOutput = "video"
  private var diagnostics: UmbelPlaybackDiagnostics?

  /// For hosts: the display layer to show in, and the device to draw with.
  /// The layer's control timebase is set synchronously on the main actor.
  /// Prefer construction there; a background caller must keep the main
  /// thread free while this initializer runs.
  public init(
    layer: AVSampleBufferDisplayLayer, device: MTLDevice, capacity: Int = 3, tolerance: CMTime
  ) throws {
    try self.init(sink: DisplayLayerSink(layer: layer), device: device, capacity: capacity, tolerance: tolerance)
    let timebase = self.timebase
    DisplayLayerAccess(layer: layer).sync { layer in layer.controlTimebase = timebase }
  }

  internal init(
    sink: any SampleBufferSink, device: MTLDevice, capacity: Int = 3, tolerance: CMTime,
    systemShowsDV: Bool = SystemDVSupport.isAvailable
  ) throws {
    self.systemShowsDV = systemShowsDV
    self.pipeline = try MetalPipeline(device: device)
    self.sink = sink
    self.queue = VideoFrameQueue(capacity: capacity, tolerance: tolerance)
    self.pixelCapacity = max(1, capacity)
    var made: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &made)
    guard let made else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a timebase")
    }
    CMTimebaseSetRate(made, rate: 0)
    self.timebase = made
  }

  public nonisolated func clockDidChange(anchor: RenderAnchor, rate: Double) {
    CMTimebaseSetRateAndAnchorTime(
      timebase, rate: rate, anchorTime: anchor.mediaTime, immediateSourceTime: anchor.hostTime)
  }

  public var queueDepth: Int { get async { await queue.depth + systemShown.count } }
  internal func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?, output: String) async {
    self.diagnostics = diagnostics
    renderSize.resetDiagnostics()
    await queue.setDiagnostics(diagnostics, output: output)
  }
  public var totalDroppedFrames: Int { get async { await queue.totalDropped } }

  public func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {
    pictureSize = PictureFit.shape(
      of: CGSize(width: Double(width) * pixelAspectRatio, height: Double(height)),
      aspectRatio: geometry.aspectRatio)
  }

  /// A drawn picture takes the shape; the layer's scaling matters only for
  /// a picture the system shows in the window (DV P5) — drawn ones go to
  /// picture in picture, which shows them whole.
  public func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) {
    geometry = PictureGeometry(aspectRatio: aspectRatio, scaling: scaling)
    needsRedraw = true
    if fillsView != nil { applyScaling() }
  }

  /// Maximum pixel size for composited output. Nil uses the source's size.
  /// Original system buffers keep their size and metadata.
  public func setRenderSize(_ size: CGSize?) {
    if renderSize.setLimit(size) { needsRedraw = true }
  }

  private func applyScaling() {
    let fills = geometry.scaling == .fill
    guard fills != fillsView else { return }
    fillsView = fills
    sink.setFillsView(fills)
  }

  public func enqueue(_ frame: VideoFrame) async throws {
    systemVideoRoute = frame.presentationRoute.isSystem
    if let sample = frame.compressedSample {
      applyScaling()
      try await send(sample, shownAt: frame.isShown ? frame.presentationTime : nil)
      observation?.observe(frame, output: observationOutput)
      return
    }
    if frame.presentationRoute == .systemPixels, let pixels = frame.pixelBuffer {
      applyScaling()
      let sample = try VideoSampleBuffer.make(of: pixels, at: frame.presentationTime, immediately: false)
      try await send(sample, shownAt: frame.isShown ? frame.presentationTime : nil, pixels: true)
      observation?.observe(frame, output: observationOutput, actual: frame.pixelDescription)
      return
    }
    await queue.enqueue(frame)
  }

  /// How far ahead of the picture showing a sample the system decodes goes
  /// to the layer, in seconds: enough for it to decode ahead. The layer
  /// itself takes nearly all it is given, and would have the rest of a film
  /// read — or downloaded — into it at once.
  private static let lead = 1.5

  /// A sample the system decodes: to the layer as it is, in the order given —
  /// decode order, which the frame queue, ordered by presentation, would
  /// break. A full layer, or a picture too far ahead of the one showing,
  /// holds it back; a flush meanwhile drops it. A layer that failed on such
  /// samples is an error: unlike a drawn picture, the stream cannot go on
  /// from any sample but a keyframe.
  private func send(_ sample: CMSampleBuffer, shownAt time: CMTime?, pixels: Bool = false) async throws {
    let sent = generation
    while !sink.isReadyForMoreMediaData || isFarAhead(time) || (pixels && hasEnoughPixelSurfaces) {
      if sink.hasFailed { throw UmbelError.videoRenderUnavailable(reason: "the system rejected the video sample") }
      // Looked at 50 times a second: paused, a sample waits long, and the
      // lead covers far more than the look's delay.
      try await Task.sleep(nanoseconds: 20_000_000)
      guard generation == sent else { return }
    }
    if sink.hasFailed {
      throw UmbelError.videoRenderUnavailable(reason: "the system could not show the picture")
    }
    sink.enqueue(sample)
    guard let time, time.isValid else { return }
    let at = systemShown.firstIndex { $0 > time } ?? systemShown.endIndex
    systemShown.insert(time, at: at)
  }

  /// Decoded surfaces need a count bound: seconds of 4K pixels are much
  /// larger than seconds of compressed packets. Clock reads make room even
  /// if the host is not calling presentFrame (for example in picture in picture).
  private var hasEnoughPixelSurfaces: Bool {
    let showing = joined?.time ?? CMTimebaseGetTime(timebase)
    return systemShown.lazy.filter { $0 > showing }.prefix(pixelCapacity).count >= pixelCapacity
  }

  /// Frames not shown — before a seek's target — are behind it and never wait.
  private func isFarAhead(_ time: CMTime?) -> Bool {
    guard let time, time.isValid else { return false }
    let showing = joined?.time ?? CMTimebaseGetTime(timebase)
    guard showing.isValid else { return false }
    return (time - showing).seconds > Self.lead
  }

  public func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    // A sample the system shows: reported once its time has come — or at
    // once, the first since a flush: a seek landing between two pictures
    // leaves the clock before the first one, which the layer shows all the
    // same, as the drawn path does (`VideoFrameQueue.take`).
    if let due = systemShown.last(where: { $0 <= time }) ?? (hasReportedSystemSample ? nil : systemShown.first) {
      systemShown.removeAll { $0 <= due }
      hasReportedSystemSample = true
      return PresentedFrame(presentationTime: due, droppedFrames: 0)
    }
    let result = await queue.take(at: time)
    guard let frame = result.frame else {
      if needsRedraw, let lastFrame { try draw(lastFrame, immediately: true) }
      return nil
    }
    try draw(frame, immediately: false)
    return PresentedFrame(presentationTime: frame.presentationTime, droppedFrames: result.dropped)
  }

  /// Forgets the last frame, and clears the layer: after a seek neither
  /// belongs.
  public func flush() async {
    generation += 1
    submissionEpoch.advance()
    systemShown.removeAll()
    hasReportedSystemSample = false
    await queue.flush()
    lastFrame = nil
    sink.flush()
    pool.reset()
    renderSize.resetDiagnostics()
  }

  public var subtitleCanvasSize: CGSize { renderSize.fitting(pictureSize) }

  public func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async {
    guard self.adjustments != adjustments else { return }
    self.adjustments = adjustments
    needsRedraw = true
  }

  public func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {
    subtitles.update(bitmaps, device: pipeline.device)
    needsRedraw = true
  }

  // ── Drawing ─────────────────────────────────────────

  /// `immediately`: a picture drawn again, not a new one — shown at once
  /// rather than at its time, long past.
  private func draw(_ frame: VideoFrame, immediately: Bool) throws {
    lastFrame = frame
    pictureSize = PictureFit.shape(of: frame.displaySize, aspectRatio: geometry.aspectRatio)
    let canvas = renderSize.fitting(pictureSize)
    let width = max(1, Int(canvas.width.rounded()))
    let height = max(1, Int(canvas.height.rounded()))
    renderSize.record(sourceWidth: frame.width, sourceHeight: frame.height, width: width, height: height,
      diagnostics: diagnostics, output: observationOutput)
    if sink.hasFailed {
      if pool.format == kCVPixelFormatType_64RGBAHalf { highPrecisionRejected = true }
      sink.flush()
    }
    // Composite HDR currently maps to SDR; precision remains an independent
    // choice. Original system samples bypass this conversion entirely.
    var output = highPrecisionRejected ? VideoOutput.standard : VideoOutput.choose(for: frame.color.transfer,
      systemShowsHDR: false, bitDepth: frame.effectiveBitDepth, primaries: frame.color.workingPrimaries)
    let target: CVPixelBuffer
    do {
      target = try pool.buffer(width: width, height: height,
        format: output == .standard ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_64RGBAHalf)
    } catch {
      guard output != .standard else { throw error }
      highPrecisionRejected = true
      output = .standard
      target = try pool.buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
    }
    if output.isLinearStandard {
      let wide = output.encoding == .standardLinear2020
      if let space = CGColorSpace(name: wide ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.extendedLinearSRGB) {
        CVBufferSetAttachment(target, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
      }
      CVBufferSetAttachment(target, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
      CVBufferSetAttachment(target, kCVImageBufferColorPrimariesKey,
        wide ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    }
    observation?.observe(frame, output: observationOutput, target: output,
      actual: .init(cvFormat: CVPixelBufferGetPixelFormatType(target)),
      reason: highPrecisionRejected ? "targetFormatUnsupported" : frame.color.isHDR ? "compositeHDRConversionNotImplemented" : nil)
    let whole = CGRect(x: 0, y: 0, width: width, height: height)

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = try pipeline.makeTargetTexture(from: target)
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let commandBuffer = pipeline.commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a command encoder")
    }
    do {
      try pipeline.encode(
        frame, output: output, subtitles: subtitles,
        layout: PictureLayout(picture: whole, visible: whole),
        adjustments: adjustments, into: encoder)
    } catch {
      encoder.endEncoding()
      throw error
    }
    encoder.endEncoding()
    needsRedraw = false

    let sample = SampleBox(try VideoSampleBuffer.make(
      of: target, at: frame.presentationTime, immediately: immediately))
    // Handed over once drawn. The handler, a sending closure, captures only
    // what is safe from any thread — never the renderer's self.
    let sink = self.sink
    let pipeline = self.pipeline
    let epoch = submissionEpoch
    let submittedAt = epoch.value
    commandBuffer.addCompletedHandler { completed in
      pipeline.releaseRetainedTextures()
      guard completed.status == .completed else { return }
      epoch.withCurrent(submittedAt) {
        if sink.hasFailed { sink.flush() }
        sink.enqueue(sample.buffer)
      }
    }
    commandBuffer.commit()
  }
}

extension SampleBufferVideoRenderer: SnapshotFrameProviding {
  public var videoCapabilities: UmbelVideoCapabilities {
    systemVideoRoute ? .systemDisplay : .pixels(hasFrame: lastFrame != nil, canScalePicture: false)
  }
  internal var snapshotFrame: VideoFrame? { lastFrame }
  internal var snapshotDevice: SnapshotDevice? { SnapshotDevice(device: pipeline.device) }
}

extension SampleBufferVideoRenderer: VideoRoutePreparing {
  internal func setSystemVideoRoute(_ system: Bool) { systemVideoRoute = system }
}

extension SampleBufferVideoRenderer: VideoPresentationObserving {
  func setVideoPresentationObservation(_ observation: VideoPresentationObservation?, output: String) {
    self.observation = observation
    observationOutput = output
  }
}

/// A sample buffer carried into the command buffer's completion handler.
/// Only read there, once; nothing else touches it.
private final class SampleBox: @unchecked Sendable {
  let buffer: CMSampleBuffer
  init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}

extension SampleBufferVideoRenderer: SystemDecodedVideoShowing {
  var showsSystemDecodedDV: Bool { systemShowsDV }
}

extension SampleBufferVideoRenderer: SystemTimelineJoining {
  /// Onto a session's system timeline, in place of its own timebase: sound
  /// and this layer's pictures then keep one time. From another timeline —
  /// the last film's, its session stopped or not — it leaves first.
  func join(_ timeline: any SystemTimeline) async throws {
    if let current = joined {
      if current === timeline { return }
      await leave()
    }
    do {
      try await sink.join(timeline, replacing: self.timebase)
    } catch {
      throw UmbelError.videoRenderUnavailable(
        reason: "the system's timeline would not take the display layer: \(error.localizedDescription)")
    }
    joined = timeline
  }

  /// Back on its own timebase, set first to where the timeline is: it
  /// heard the clock's commands meanwhile, but not the system's start-up
  /// delay, and would be a fraction of a second off.
  func leave() async {
    guard let timeline = joined else { return }
    joined = nil
    CMTimebaseSetTime(timebase, time: timeline.time)
    await sink.leave(timeline, restoring: self.timebase)
  }
}

extension SampleBufferVideoRenderer: FrameSeeding {
  func seed(_ frame: VideoFrame) async { await queue.seed(frame) }
}

extension SampleBufferVideoRenderer: PictureRenderSizing {}
