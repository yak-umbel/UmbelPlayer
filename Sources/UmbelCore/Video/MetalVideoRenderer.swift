import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// A renderer that draws to a display layer.
///
/// It shares its pipeline with the offscreen renderer and differs only in
/// where it draws: the drawables the display layer provides. It too **owns
/// no display loop**: the caller asks what to draw at time T, at its own
/// refresh rate.
///
/// **The host sizes the layer's drawable to its view, in pixels**, and keeps
/// it so on resize, as MTKView does for its own. The picture is fitted into
/// it with black bars, and subtitles are drawn at that resolution: text
/// stays sharp however small the video, which drawing at the video's size
/// and letting the layer scale it would not give. Until the host sizes it,
/// the drawable is the video's size.
///
/// **The renderer owns the layer's pixel format, colour space and extended
/// dynamic range settings**: it sets them for each kind of picture, HDR
/// or not. A host should leave them alone; one set back is set up again
/// before the next picture is drawn.
public actor MetalVideoRenderer: VideoRenderer, VideoDiagnosticsReceiving {
  private let pipeline: MetalPipeline
  private let layer: CAMetalLayer
  private let queue: VideoFrameQueue
  private let dynamicRange: UmbelDynamicRange
  private var policyRange: UmbelDynamicRange?
  private var color = VideoColorDescription(matrix: .unspecified, range: .limited)
  /// The picture as shown, before fitting: stored pixels at their shape.
  private var pictureSize = CGSize.zero
  private var subtitles = SubtitleOverlay()
  /// Drawn again when the subtitles or the drawable size change and no new
  /// frame is due.
  private var lastFrame: VideoFrame?
  private var needsRedraw = false
  private var adjustments = UmbelVideoAdjustments()
  /// How the layer is set: standard range, or PQ / HLG in extended dynamic
  /// range. Nil until the first `prepare`.
  private var setup: DisplayLayerSetup?
  private var drawnSize = CGSize.zero
  /// Drawing only subtitles, the layer see-through, over a picture the
  /// system shows beneath (DV profile 5).
  private var overlaysSystemPicture = false
  /// The host's shape and scaling for the picture.
  private var geometry = PictureGeometry.standard
  private var observation: VideoPresentationObservation?
  private var observationOutput = "video"

  /// For hosts: a display layer is all it takes; the pipeline is made inside.
  ///
  /// `dynamicRange`: HDR is shown as HDR where the system can show it,
  /// unless the host asks for standard range.
  public init(
    layer: CAMetalLayer,
    device: MTLDevice,
    dynamicRange: UmbelDynamicRange = .automatic,
    capacity: Int = 3,
    tolerance: CMTime
  ) throws {
    self.pipeline = try MetalPipeline(device: device)
    self.layer = layer
    self.dynamicRange = dynamicRange
    self.queue = VideoFrameQueue(capacity: capacity, tolerance: tolerance)
  }

  /// For tests: shares a pipeline with other renderers.
  internal init(
    pipeline: MetalPipeline,
    layer: CAMetalLayer,
    dynamicRange: UmbelDynamicRange = .automatic,
    capacity: Int = 3,
    tolerance: CMTime
  ) {
    self.pipeline = pipeline
    self.layer = layer
    self.dynamicRange = dynamicRange
    self.queue = VideoFrameQueue(capacity: capacity, tolerance: tolerance)
  }

  public var queueDepth: Int { get async { await queue.depth } }
  internal func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?, output: String) async {
    await queue.setDiagnostics(diagnostics, output: output)
  }
  public var totalDroppedFrames: Int { get async { await queue.totalDropped } }

  public func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {
    self.color = color
    layer.device = pipeline.device
    // From the track's word, so the layer is ready for HDR before its first frame.
    await configure(for: color)
    pictureSize = CGSize(width: Double(width) * pixelAspectRatio, height: Double(height))
    if layer.drawableSize.width < 1 || layer.drawableSize.height < 1 {
      layer.drawableSize = CGSize(
        width: pictureSize.width.rounded(), height: pictureSize.height.rounded())
    }
  }

  public func enqueue(_ frame: VideoFrame) async throws {
    await queue.enqueue(frame)
  }

  public func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    if overlaysSystemPicture {
      // The picture is the system's: only the subtitles, when they or the
      // size change.
      if needsRedraw || layer.drawableSize != drawnSize { try await drawSubtitlesOnly() }
      return nil
    }
    let result = await queue.take(at: time)
    guard let frame = result.frame else {
      // Paused through a resize, the old drawable would stay stretched.
      let resized = layer.drawableSize != drawnSize
      if needsRedraw || resized, let lastFrame { try await draw(lastFrame) }
      return nil
    }
    try await draw(frame)
    return PresentedFrame(
      presentationTime: frame.presentationTime, droppedFrames: result.dropped)
  }

  /// Forgets the last frame too: after a seek it no longer belongs.
  public func flush() async {
    await queue.flush()
    lastFrame = nil
  }

  /// The part of the picture that shows in the drawable, in pixels.
  public var subtitleCanvasSize: CGSize { layout(in: layer.drawableSize).visible.size }

  public var subtitlePictureFrame: CGRect {
    let laid = layout(in: layer.drawableSize)
    return laid.picture.offsetBy(dx: -laid.visible.minX, dy: -laid.visible.minY)
  }

  public func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) {
    geometry = PictureGeometry(aspectRatio: aspectRatio, scaling: scaling)
    needsRedraw = true
  }

  /// The picture laid out in an output of `size`. Over a picture the system
  /// shows, its shape is the system's: only the scaling applies there.
  private func layout(in size: CGSize) -> PictureLayout {
    let applied = overlaysSystemPicture
      ? PictureGeometry(aspectRatio: nil, scaling: geometry.scaling) : geometry
    return PictureFit.layout(picture: pictureSize, in: size, geometry: applied)
  }

  public func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async {
    guard self.adjustments != adjustments else { return }
    self.adjustments = adjustments
    needsRedraw = true
  }

  public func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {
    subtitles.update(bitmaps, device: pipeline.device)
    needsRedraw = true
  }

  /// Sets the layer up for pictures of this colour, on the main thread, when
  /// that differs from how it is set: once per film as a rule.
  private func configure(for color: VideoColorDescription, bitDepth: Int? = 8) async {
    let wanted = DisplayLayerSetup(
      output: VideoOutput.choose(
        for: color.transfer,
        systemShowsHDR: (policyRange ?? dynamicRange) == .automatic && VideoOutput.systemShowsHDR,
        bitDepth: bitDepth, primaries: color.workingPrimaries),
      metadata: color.hdr)
    // The layer itself is checked, not only what was last set: a host that
    // changed it would otherwise have HDR half floats drawn into an 8-bit
    // drawable, which shows as garbage colours.
    guard wanted != setup || layer.pixelFormat != wanted.output.pixelFormat else { return }
    setup = wanted
    let handle = MainThreadLayer(layer: layer)
    await MainActor.run { wanted.apply(to: handle.layer) }
  }

  private func draw(_ frame: VideoFrame) async throws {
    lastFrame = frame
    // The frame's own shape: the track may not have said, and a broadcast
    // may change it mid-stream.
    pictureSize = frame.displaySize
    await configure(for: frame.color, bitDepth: frame.effectiveBitDepth)
    let output = setup?.output ?? .standard
    observation?.observe(frame, output: observationOutput, target: output)
    do {
      try render(clear: Self.pictureClear) { encoder, size in
        try pipeline.encode(
          frame, output: output, subtitles: subtitles,
          layout: layout(in: size), adjustments: adjustments, into: encoder)
      }
    } catch {
      needsRedraw = true
      throw error
    }
  }

  /// The subtitles alone, over nothing: the picture beneath is the system's,
  /// fitted into the same bounds by the same rule, so they land on it.
  private func drawSubtitlesOnly() async throws {
    await configure(for: VideoColorDescription(matrix: .unspecified, range: .limited))
    try render(clear: Self.overlayClear) { encoder, size in
      try pipeline.encodeSubtitles(
        subtitles, output: .standard, layout: layout(in: size),
        into: encoder)
    }
  }

  /// A picture of its own goes on black, bars and all.
  internal static let pictureClear = MTLClearColorMake(0, 0, 0, 1)
  /// Subtitles over the system's picture go on nothing: it shows through.
  internal static let overlayClear = MTLClearColorMake(0, 0, 0, 0)

  /// One pass into the next drawable: cleared, encoded, presented.
  ///
  /// No drawable, no drawing this round: the display loop comes dozens of
  /// times a second, and a window not yet on screen or of zero size has
  /// none — normal, not an error. A redraw it misses is retried on the next
  /// call.
  private func render(
    clear: MTLClearColor, _ encode: (MTLRenderCommandEncoder, CGSize) throws -> Void
  ) throws {
    try Task.checkCancellation()
    let drawable = layer.nextDrawable()
    try Task.checkCancellation()
    guard let drawable else { return }
    // The drawable's own size: the host may resize between asking and drawing.
    let output = CGSize(width: drawable.texture.width, height: drawable.texture.height)

    let descriptor = MTLRenderPassDescriptor()
    descriptor.colorAttachments[0].texture = drawable.texture
    descriptor.colorAttachments[0].loadAction = .clear
    descriptor.colorAttachments[0].storeAction = .store
    descriptor.colorAttachments[0].clearColor = clear

    guard let commandBuffer = pipeline.commandQueue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot create a command encoder")
    }

    do {
      try encode(encoder, output)
    } catch {
      encoder.endEncoding()
      throw error
    }
    encoder.endEncoding()
    try Task.checkCancellation()

    commandBuffer.present(drawable)

    // On screen, rendering **does not wait**: waiting would stall the display
    // loop. The textures are released by the completion handler, a sending
    // closure that captures only the pipeline, which is Sendable — never the
    // renderer's self.
    let pipeline = self.pipeline
    commandBuffer.addCompletedHandler { _ in
      pipeline.releaseRetainedTextures()
    }
    commandBuffer.commit()
    needsRedraw = false
    drawnSize = output
  }
}

extension MetalVideoRenderer: VideoPresentationObserving {
  var dynamicRangeConstraint: UmbelDynamicRange { dynamicRange }
  func setVideoPolicy(_ policy: UmbelVideoPolicy) { policyRange = policy.dynamicRange }
  func setVideoPresentationObservation(_ observation: VideoPresentationObservation?, output: String) {
    self.observation = observation
    observationOutput = output
  }
}

/// A window's renderer that can draw only subtitles, see-through, over a
/// picture the system shows beneath it.
internal protocol SystemPictureOverlay: Actor {
  func setOverlaysSystemPicture(_ overlays: Bool) async
}

extension MetalVideoRenderer: SystemPictureOverlay {
  /// Into the overlay: frames and the last picture go, the layer turns
  /// see-through and standard range. Out of it: opaque again, drawn anew by
  /// the next frame.
  func setOverlaysSystemPicture(_ overlays: Bool) async {
    guard overlays != overlaysSystemPicture else { return }
    overlaysSystemPicture = overlays
    await queue.flush()
    lastFrame = nil
    needsRedraw = true
    let handle = MainThreadLayer(layer: layer)
    await MainActor.run { handle.layer.isOpaque = !overlays }
  }
}

/// A window's renderer whose picture has gone to picture in picture.
internal protocol PictureSteppingAside: Actor {
  /// Aside, it shows nothing of its own, and what is beneath shows through:
  /// the system's layer, where the small window comes back to. Showing the
  /// picture from when the small window opened, it covered the one coming
  /// back, and flashed an old picture. Back, the next frame draws it anew.
  func stepAside(_ aside: Bool) async
}

extension MetalVideoRenderer: PictureSteppingAside {
  func stepAside(_ aside: Bool) async {
    await queue.flush()
    lastFrame = nil
    needsRedraw = true
    let handle = MainThreadLayer(layer: layer)
    let opaque = !aside && !overlaysSystemPicture
    await MainActor.run { handle.layer.isOpaque = opaque }
    // Cleared at once: nothing else draws while the picture is away.
    if aside { try? render(clear: Self.overlayClear) { _, _ in } }
  }
}

extension MetalVideoRenderer: SnapshotFrameProviding {
  public var videoCapabilities: UmbelVideoCapabilities {
    overlaysSystemPicture ? .systemDisplay : .pixels(hasFrame: lastFrame != nil)
  }
  internal var snapshotFrame: VideoFrame? { lastFrame }
  internal var snapshotDevice: SnapshotDevice? { SnapshotDevice(device: pipeline.device) }
}

extension MetalVideoRenderer: PictureFrameReporting {
  internal var normalizedPictureFrame: CGRect? {
    guard lastFrame != nil || overlaysSystemPicture else { return nil }
    let output = layer.drawableSize
    guard output.width > 0, output.height > 0 else { return nil }
    let picture = layout(in: output).picture
    return CGRect(x: picture.minX / output.width, y: picture.minY / output.height,
                  width: picture.width / output.width, height: picture.height / output.height)
  }
}

extension MetalVideoRenderer: FrameSeeding {
  func seed(_ frame: VideoFrame) async { await queue.seed(frame) }
}
