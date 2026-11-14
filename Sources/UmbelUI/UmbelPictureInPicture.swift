#if os(macOS) || os(iOS) || os(tvOS)
import AVKit
import CoreMedia
import UmbelCore

/// Picture in picture for a session that draws through a
/// `SwitchingVideoRenderer` whose second renderer is a
/// `SampleBufferVideoRenderer` showing in `layer`.
///
/// The layer has to be in a window, on screen, for the system to open the
/// small window from it. Opening switches the picture to it, closing
/// switches it back; the window's play, pause and skip buttons act on the
/// session. Main thread only.
///
/// On macOS the small window mirrors the layer as it is — pixel for pixel,
/// from its corner, not scaled to fit — so while it is open the layer takes
/// the small window's size, following it as it is resized, and gets its own
/// back when it closes. A host laying the layer out should leave its size
/// alone meanwhile. The system also lays a black view over the picture in
/// the small window — a band across its top — which is hidden. The small
/// window is the panel the system opens in the process, known by its class,
/// or failing that the one window that was not there before.
@MainActor
public final class UmbelPictureInPicture {
  public let playback: PictureInPicturePlayback
  private let controller: AVPictureInPictureController
  private let delegate: Delegate
  private let layer: AVSampleBufferDisplayLayer
  /// The layer's frame before the small window opened.
  private var frameBefore: CGRect?
  #if os(macOS)
  private var windowsBefore: Set<ObjectIdentifier> = []
  private var resizing: NSObjectProtocol?
  #endif
  #if os(iOS)
  /// The driver drawing the session's pictures, told when the small window
  /// opens and closes: it then goes on drawing in the background, where the
  /// small window would otherwise stand still.
  public weak var displayDriver: UmbelDisplayDriver?
  #endif

  /// Nil where the system has no picture in picture.
  public init?(layer: AVSampleBufferDisplayLayer, session: PlaybackSession, renderer: SwitchingVideoRenderer) {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
    let playback = PictureInPicturePlayback(session: session, renderer: renderer)
    let delegate = Delegate(playback: playback)
    let controller = AVPictureInPictureController(
      contentSource: AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: layer, playbackDelegate: delegate))
    controller.delegate = delegate
    playback.onChange = { [weak controller] in controller?.invalidatePlaybackState() }
    self.playback = playback
    self.controller = controller
    self.delegate = delegate
    self.layer = layer
    delegate.owner = self
    Task { await playback.refresh() }
  }

  /// Whether the small window can open now: the layer is on screen and has
  /// something to show.
  public var isPossible: Bool { controller.isPictureInPicturePossible }
  public var isActive: Bool { controller.isPictureInPictureActive }

  public func start() {
    let scale = layer.contentsScale
    let initialSize = CGSize(width: layer.bounds.width * scale, height: layer.bounds.height * scale)
    Task {
      await playback.renderer.setPictureInPictureRenderSize(initialSize)
      // The switch comes first, and the window opens once the layer shows a
      // picture: opened from an empty one, the system's window has no size
      // to take, and the process ends.
      await playback.started()
      for _ in 0..<100 where await !playback.renderer.hasPresentedSinceSwitch {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      guard await playback.renderer.hasPresentedSinceSwitch else {
        await playback.stopped()
        return
      }
      // Drawn; on the layer once the GPU is done with it.
      try? await Task.sleep(nanoseconds: 100_000_000)
      #if os(macOS)
      windowsBefore = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
      #endif
      controller.startPictureInPicture()
    }
  }

  public func stop() {
    controller.stopPictureInPicture()
  }

  /// The small window is opening, or has closed or failed to open.
  fileprivate func windowIsOpen(_ open: Bool) {
    #if os(iOS)
    displayDriver?.setPictureInPictureActive(open)
    #endif
  }

  /// The small window has opened: the layer takes its size, in the middle of
  /// where it was, and follows it.
  fileprivate func followSmallWindow() {
    #if os(macOS)
    guard let content = Self.smallWindow(among: NSApplication.shared.windows, before: windowsBefore)?
      .contentView, frameBefore == nil else { return }
    frameBefore = layer.frame
    fit(content.bounds.size)
    content.postsFrameChangedNotifications = true
    resizing = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification, object: content, queue: .main
    ) { [weak self, weak content] _ in
      MainActor.assumeIsolated {
        if let size = content?.bounds.size { self?.fit(size) }
        if let content { Self.hideBlackCover(in: content) }
      }
    }
    // Laid in a moment after the window opens.
    Task { @MainActor [weak content] in
      try? await Task.sleep(nanoseconds: 100_000_000)
      if let content { Self.hideBlackCover(in: content) }
    }
    #endif
  }

  #if os(macOS)
  /// The small window among `windows`: a new one whose class is the
  /// system's panel for it — so another opening at that moment is not taken
  /// instead — or else the first new one, should the class be named
  /// otherwise some day.
  static func smallWindow(among windows: [NSWindow], before: Set<ObjectIdentifier>) -> NSWindow? {
    let new = windows.filter { !before.contains(ObjectIdentifier($0)) }
    return new.first { String(describing: type(of: $0)).hasSuffix("PIPPanel") } ?? new.first
  }

  /// Hides the black view the small window lays over the picture on macOS:
  /// solid, scaled down, and showing as a band across the top. Known by its
  /// class; should a later system name it otherwise, nothing is hidden.
  static func hideBlackCover(in view: NSView) {
    if String(describing: type(of: view)) == "AVPictureInPictureCALayerHostView" {
      view.isHidden = true
      return
    }
    for sub in view.subviews { hideBlackCover(in: sub) }
  }
  #endif

  /// A frame of `size` in the middle of `bounds`.
  static func centred(_ size: CGSize, in bounds: CGRect) -> CGRect {
    CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
  }

  /// While picture in picture is open, `size` in the middle of the frame the
  /// layer had; closed, that frame again.
  private func fit(_ size: CGSize) {
    guard size.width >= 1, size.height >= 1 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = frameBefore.map { Self.centred(size, in: $0) } ?? CGRect(origin: layer.frame.origin, size: size)
    CATransaction.commit()
  }

  fileprivate func restore() {
    #if os(macOS)
    if let resizing { NotificationCenter.default.removeObserver(resizing) }
    resizing = nil
    #endif
    guard let frameBefore else { return }
    self.frameBefore = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = frameBefore
    CATransaction.commit()
  }
}

/// The system's delegate calls, on the main thread, handed to the playback.
private final class Delegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate,
  AVPictureInPictureControllerDelegate, @unchecked Sendable {
  let playback: PictureInPicturePlayback
  weak var owner: UmbelPictureInPicture?

  init(playback: PictureInPicturePlayback) {
    self.playback = playback
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool
  ) {
    let playback = self.playback
    Task { @MainActor in await playback.setPlaying(playing) }
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    MainActor.assumeIsolated { playback.timeRange }
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    MainActor.assumeIsolated { playback.isPaused }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    guard newRenderSize.width > 0, newRenderSize.height > 0 else { return }
    let playback = self.playback
    let size = CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
    Task { @MainActor in await playback.renderer.setPictureInPictureRenderSize(size) }
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    MainActor.assumeIsolated { owner?.followSmallWindow() }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void
  ) {
    let playback = self.playback
    let done = Completion(completionHandler)
    Task { @MainActor in
      await playback.skip(by: skipInterval)
      done.call()
    }
  }

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    MainActor.assumeIsolated { owner?.windowIsOpen(true) }
    let playback = self.playback
    Task { @MainActor in await playback.started() }
  }

  /// Refused — the layer went off screen, say: the picture comes back.
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    MainActor.assumeIsolated { owner?.windowIsOpen(false) }
    let playback = self.playback
    Task { @MainActor in await playback.stopped() }
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    MainActor.assumeIsolated {
      owner?.restore()
      owner?.windowIsOpen(false)
    }
    let playback = self.playback
    Task { @MainActor in await playback.stopped() }
  }
}

/// The system's completion handler, called once from the main actor.
private final class Completion: @unchecked Sendable {
  private let handler: () -> Void
  init(_ handler: @escaping () -> Void) { self.handler = handler }
  func call() { handler() }
}
#endif
