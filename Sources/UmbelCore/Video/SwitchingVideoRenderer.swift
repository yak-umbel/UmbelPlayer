import CoreGraphics
import CoreMedia
import Metal

/// Two renderers, one shown at a time: the window's, and picture in
/// picture's. Handed to a session as its renderer, it swaps them while
/// playing — frames, presenting and subtitles go to the one shown.
///
/// Both are prepared, and both follow the clock all along when they can, so
/// either can take over at any moment with its timing already right. On a
/// swap both are flushed — the one arriving first, then the one left — and
/// the picture and subtitles showing go to the one arriving, so it has them
/// at once, paused too: the system opens picture in picture from what its
/// layer shows, and from nothing it fails. The few frames queued for the
/// one left are dropped: a swap happens while the system animates the
/// window, and decoding refills the queue within a tenth of a second.
///
/// Pictures only the system can show, compressed or already decoded,
/// go to picture in picture's side — the system's display
/// layer — in the window and in picture in picture alike, while the window's
/// renderer draws the subtitles alone over it. Nothing is swapped then;
/// while that picture is in picture in picture the window's overlay is
/// cleared — it would show subtitles over a placeholder.
public actor SwitchingVideoRenderer: VideoRenderer, ClockFollower, VideoDiagnosticsReceiving {
  public enum Output: Sendable, Equatable {
    case main
    case pictureInPicture
  }

  private let main: any VideoRenderer
  private let pictureInPicture: any VideoRenderer
  public private(set) var active = Output.main
  /// Up by one on each swap: a frame whose hand-over waited across one goes
  /// to the renderer now shown.
  private var swaps = 0
  private var lastSubtitles: [UmbelSubtitleBitmap] = []
  /// Frames handed on and not yet shown, and the one showing: the renderers
  /// hold them anyway, so keeping them costs nothing.
  private var recent: [VideoFrame] = []
  private var showing: VideoFrame?
  /// Whether the renderer shown has presented a frame since the last swap.
  public private(set) var hasPresentedSinceSwitch = true
  /// The system shows the picture on picture in picture's side; the main
  /// renderer is the subtitle overlay.
  private var systemShowsPicture = false
  private var hasPresentedSystemPicture = false
  private var diagnostics: UmbelPlaybackDiagnostics?
  private var observation: VideoPresentationObservation?
  private var observationOutput = "video"

  internal func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?, output: String) async {
    self.diagnostics = diagnostics
    await (main as? any VideoDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics, output: output + ".main")
    await (pictureInPicture as? any VideoDiagnosticsReceiving)?.setPlaybackDiagnostics(
      diagnostics, output: output + ".pictureInPicture")
  }

  public init(main: any VideoRenderer, pictureInPicture: any VideoRenderer) {
    self.main = main
    self.pictureInPicture = pictureInPicture
  }

  /// The pixel size requested by the system's small window. Composited
  /// output fits within it; original system buffers remain untouched.
  public func setPictureInPictureRenderSize(_ size: CGSize?) async {
    await (pictureInPicture as? any PictureRenderSizing)?.setRenderSize(size)
  }

  private var current: any VideoRenderer { active == .main ? main : pictureInPicture }
  internal var systemPixelCapability: Bool {
    get async { await (pictureInPicture as? any SystemPixelVideoShowing)?.showsP84SystemPixels ?? false }
  }
  internal var p81SystemPixelCapability: Bool {
    get async { await (pictureInPicture as? any SystemPixelVideoShowing)?.showsP81SystemPixels ?? false }
  }
  internal var p5SystemPixelCapability: Bool {
    get async { await (pictureInPicture as? any SystemPixelVideoShowing)?.showsP5SystemPixels ?? false }
  }

  /// Shows `output` from the next frame on.
  public func show(_ output: Output) async {
    guard output != active else { return }
    diagnostics?.record("video_output_switch", values: ["swaps": Double(swaps)],
                        labels: ["from": String(describing: active), "to": String(describing: output),
                                 "systemShowsPicture": String(systemShowsPicture)])
    if systemShowsPicture {
      // The picture is on the system's layer already, for both.
      active = output
      await updateSystemObservationOutput()
      hasPresentedSinceSwitch = true
      await main.setSubtitles(overlaySubtitles)
      return
    }
    let leaving = current
    active = output
    swaps += 1
    // The one arriving first: a frame released from the one left is handed
    // to it next, and must not be flushed away.
    await current.flush()
    await leaving.flush()
    await (main as? any PictureSteppingAside)?.stepAside(output == .pictureInPicture)
    await current.setSubtitles(lastSubtitles)
    hasPresentedSinceSwitch = false
    recent.removeAll()
    if let showing { await handOver(showing) }
  }

  /// The picture showing goes to the output arriving, apart from its queue:
  /// decoding may have filled that the moment it was flushed, and paused,
  /// nothing takes from it, so queued behind, the switch waited for good.
  /// A host's renderer that cannot take it so gets it queued, without the
  /// switch waiting: a flush lets that go.
  private func handOver(_ frame: VideoFrame) async {
    if let seeding = current as? any FrameSeeding { return await seeding.seed(frame) }
    let renderer = current
    Task { try? await renderer.enqueue(frame) }
  }

  public nonisolated func clockDidChange(anchor: RenderAnchor, rate: Double) {
    (main as? any ClockFollower)?.clockDidChange(anchor: anchor, rate: rate)
    (pictureInPicture as? any ClockFollower)?.clockDidChange(anchor: anchor, rate: rate)
  }

  public func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {
    try await main.prepare(width: width, height: height, pixelAspectRatio: pixelAspectRatio, color: color)
    try await pictureInPicture.prepare(
      width: width, height: height, pixelAspectRatio: pixelAspectRatio, color: color)
  }

  public func enqueue(_ frame: VideoFrame) async throws {
    let system = frame.presentationRoute.isSystem
    if system != systemShowsPicture { await setSystemShowsPicture(system) }
    if systemShowsPicture {
      // Both outputs use the same layer. No hand-over copy is needed;
      // retaining these surfaces would grow without bound when host ticks
      // stop while the system continues playing in picture in picture.
      try await pictureInPicture.enqueue(frame)
      return
    }
    let before = swaps
    recent.append(frame)
    try await current.enqueue(frame)
    // Swapped while it waited on a full queue: the flush let it go into the
    // renderer left, which will not show it.
    if swaps != before { try await current.enqueue(frame) }
  }

  public func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    if systemShowsPicture {
      _ = try await main.presentFrame(at: time)
      let presented = try await pictureInPicture.presentFrame(at: time)
      if presented != nil {
        hasPresentedSinceSwitch = true
        hasPresentedSystemPicture = true
      }
      return presented
    }
    guard let presented = try await current.presentFrame(at: time) else { return nil }
    hasPresentedSinceSwitch = true
    let shown = presented.presentationTime
    if let frame = recent.last(where: { $0.presentationTime == shown }) { showing = frame }
    recent.removeAll { $0.presentationTime <= shown }
    return presented
  }

  public func flush() async {
    recent.removeAll()
    showing = nil
    hasPresentedSystemPicture = false
    await main.flush()
    await pictureInPicture.flush()
  }

  /// The renderer that has the frames, and the one that draws the subtitles.
  private var framesSide: any VideoRenderer { systemShowsPicture ? pictureInPicture : current }
  private var subtitleSide: any VideoRenderer { systemShowsPicture ? main : current }
  /// What the window's overlay shows over the system's picture: nothing
  /// while that picture is in picture in picture.
  private var overlaySubtitles: [UmbelSubtitleBitmap] { active == .main ? lastSubtitles : [] }

  public var queueDepth: Int { get async { await framesSide.queueDepth } }
  public var totalDroppedFrames: Int { get async { await framesSide.totalDroppedFrames } }
  public var subtitleCanvasSize: CGSize { get async { await subtitleSide.subtitleCanvasSize } }
  public var subtitlePictureFrame: CGRect { get async { await subtitleSide.subtitlePictureFrame } }

  /// Both sides alike, so either can take over with the picture as it was.
  public func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {
    await main.setPictureGeometry(aspectRatio: aspectRatio, scaling: scaling)
    await pictureInPicture.setPictureGeometry(aspectRatio: aspectRatio, scaling: scaling)
  }

  public func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async {
    await main.setVideoAdjustments(adjustments)
    await pictureInPicture.setVideoAdjustments(adjustments)
  }

  public func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {
    lastSubtitles = bitmaps
    await subtitleSide.setSubtitles(systemShowsPicture ? overlaySubtitles : bitmaps)
  }

  /// Into or out of the system showing the picture: the main renderer turns
  /// into the subtitle overlay, or back, and has the subtitles showing. Out
  /// of it, the system's last picture leaves its layer.
  private func setSystemShowsPicture(_ shows: Bool) async {
    systemShowsPicture = shows
    hasPresentedSystemPicture = false
    await (main as? any SystemPictureOverlay)?.setOverlaysSystemPicture(shows)
    if !shows { await pictureInPicture.flush() }
    recent.removeAll()
    showing = nil
    await subtitleSide.setSubtitles(shows ? overlaySubtitles : lastSubtitles)
    await updateSystemObservationOutput()
  }

  private func updateSystemObservationOutput() async {
    await (pictureInPicture as? any VideoPresentationObserving)?.setVideoPresentationObservation(
      observation, output: observationOutput + (systemShowsPicture && active == .main ? ".main" : ".pictureInPicture"))
  }
}

extension SwitchingVideoRenderer: VideoPresentationObserving {
  var dynamicRangeConstraint: UmbelDynamicRange {
    get async { await (main as? any VideoPresentationObserving)?.dynamicRangeConstraint ?? .automatic }
  }
  func setVideoPolicy(_ policy: UmbelVideoPolicy) async {
    await (main as? any VideoPresentationObserving)?.setVideoPolicy(policy)
    await (pictureInPicture as? any VideoPresentationObserving)?.setVideoPolicy(policy)
  }
  func setVideoPresentationObservation(_ observation: VideoPresentationObservation?, output: String) async {
    self.observation = observation
    observationOutput = output
    await (main as? any VideoPresentationObserving)?.setVideoPresentationObservation(observation, output: output + ".main")
    await updateSystemObservationOutput()
  }
}

/// A renderer that takes a picture apart from its queue, shown next: the
/// one showing on the other output, handed over on a switch.
internal protocol FrameSeeding: Actor {
  func seed(_ frame: VideoFrame) async
}

internal protocol PictureRenderSizing: Actor {
  func setRenderSize(_ size: CGSize?) async
}

extension SwitchingVideoRenderer: SnapshotFrameProviding {
  public var videoCapabilities: UmbelVideoCapabilities {
    get async {
      var result = await framesSide.videoCapabilities
      if systemShowsPicture { result.subtitles = active == .main ? .separateOverlay : .unavailable }
      return result
    }
  }
  internal var snapshotFrame: VideoFrame? {
    get async {
      if systemShowsPicture { return nil }
      return await (framesSide as? any SnapshotFrameProviding)?.snapshotFrame
    }
  }
  internal var snapshotDevice: SnapshotDevice? {
    get async { await (framesSide as? any SnapshotFrameProviding)?.snapshotDevice }
  }
}

extension SwitchingVideoRenderer: VideoRoutePreparing {
  internal func setSystemVideoRoute(_ system: Bool) async {
    await (pictureInPicture as? any VideoRoutePreparing)?.setSystemVideoRoute(system)
    await setSystemShowsPicture(system)
  }
}

extension SwitchingVideoRenderer: PictureFrameReporting {
  internal var normalizedPictureFrame: CGRect? {
    get async {
      guard active == .main, systemShowsPicture ? hasPresentedSystemPicture : showing != nil else { return nil }
      return await (main as? any PictureFrameReporting)?.normalizedPictureFrame
    }
  }
}

extension SwitchingVideoRenderer: SystemDecodedVideoShowing {
  /// Asked of picture in picture's side, whose layer the system would show on.
  var showsSystemDecodedDV: Bool {
    get async { await (pictureInPicture as? any SystemDecodedVideoShowing)?.showsSystemDecodedDV ?? false }
  }
}

extension SwitchingVideoRenderer: SystemTimelineJoining {
  /// Picture in picture's side has the display layer.
  func join(_ timeline: any SystemTimeline) async throws {
    try await (pictureInPicture as? any SystemTimelineJoining)?.join(timeline)
  }

  func leave() async {
    await (pictureInPicture as? any SystemTimelineJoining)?.leave()
  }
}
