import AppKit
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import UmbelCore

/// Diagnostics gathered while playing.
///
/// Watching can only judge whether things look right; drift is a number,
/// and needs somewhere to be written down.
actor PlaybackStats {
  private(set) var presented = 0
  private(set) var dropped = 0
  /// How many milliseconds early or late the latest frame was against the
  /// clock.
  private(set) var lastOffsetMilliseconds = 0.0
  /// Display callbacks skipped because the last one had not finished drawing.
  private(set) var skipped = 0
  private var isPresenting = false
  /// Whether there has been a seek.
  ///
  /// The offset is position minus wall time elapsed, which holds only for
  /// playing straight through from the start; after a seek or a pause it is
  /// arithmetic noise. Better to own up to that than print a number to be
  /// misread.
  private(set) var hasSeeked = false
  /// Whether there has been a pause; see `hasSeeked`.
  private(set) var hasPaused = false
  /// Whether the rate has changed; see `hasSeeked`.
  private(set) var hasChangedRate = false

  /// Where the latest seek went, until a frame from there is shown.
  private var seekTarget: Double?

  func markSeeked(to target: Double? = nil) {
    hasSeeked = true
    seekTarget = target
  }

  func markPaused() { hasPaused = true }

  func markRateChanged() { hasChangedRate = true }

  /// The display callback comes every tick; a tick whose last one has not
  /// finished drawing is skipped.
  ///
  /// Without this gate the callback starts tasks unthrottled: once
  /// nextDrawable starts waiting for vsync the tasks pile up, the whole
  /// backlog stands between presenting a frame and reading the clock, and the
  /// measured difference sits hundreds of milliseconds negative — the
  /// picture is right and the reading is false.
  func beginPresent() -> Bool {
    if isPresenting {
      skipped += 1
      return false
    }
    isPresenting = true
    return true
  }

  func endPresent() { isPresenting = false }

  func record(frameTime: CMTime, clock: CMTime, droppedFrames: Int) {
    presented += 1
    dropped += droppedFrames
    lastOffsetMilliseconds = (frameTime.seconds - clock.seconds) * 1000
    if presented == 1 {
      Trace.log(String(format: "first-frame %.3f", frameTime.seconds))
    }
    // Frames from before the seek keep coming until it lands.
    if let target = seekTarget, abs(frameTime.seconds - target) < 2 {
      seekTarget = nil
      Trace.log(String(format: "seek-frame %.3f", frameTime.seconds))
    }
  }
}

/// Holds the display layer.
///
/// Both sides touch it: AppKit puts it into the view on the main thread, and
/// the renderer draws into it on its own executor. The compiler cannot prove
/// that safe; the safety is in discipline — the window loads it once, when
/// made, and after that only the renderer draws; the main thread changes
/// only the drawable's size, as MTKView does. The discipline is written down
/// here rather than scattered over the call sites.
struct DisplayLayerHandle: @unchecked Sendable {
  let layer: CAMetalLayer

  init() {
    layer = CAMetalLayer()
  }
}

/// The smallest playback window.
///
/// The display loop is driven from here — the core holds no display link on
/// purpose (none of the system's display link interfaces reaches this
/// project's platform floor, and holding one in the core would mean version
/// branches and deprecated calls). `CVDisplayLink`'s deprecation warnings
/// stay in the example.
///
/// The caller passes the display layer in rather than it being made here:
/// the renderer needs it when constructed, before the media is open and the
/// picture's size known.
///
/// The whole class is on the main actor: AppKit's types are main-actor
/// isolated themselves and a non-isolated class may not touch them. The
/// display callback alone is not — it is called on its own thread.
@MainActor
final class PlayerWindow: NSObject {
  private let window: NSWindow
  private let session: PlaybackSession
  private let stats: PlaybackStats
  private let layer: CAMetalLayer
  private var displayLink: CVDisplayLink?
  private var keyMonitor: Any?
  /// Where repeated presses add up to.
  ///
  /// Reading the clock and adding to it each time will not do: pressed in
  /// quick succession, the last seek has not landed yet and the old position
  /// is read, and ten presses do not go ten times as far. Players keep their
  /// own target and fold seek requests together — which is what the core's
  /// "only the last one counts" is for.
  private var desiredSeconds: Double?
  /// The key p, with --pip.
  var onPictureInPicture: (() -> Void)?

  var contentView: NSView? { window.contentView }
  /// The picture's own view, so the system's display layer can go above it
  /// (picture in picture) or below it (a picture only the system can show,
  /// with the subtitles drawn over it here).
  let pictureView: NSView

  init(
    session: PlaybackSession,
    stats: PlaybackStats,
    layer: CAMetalLayer,
    width: Int,
    height: Int
  ) {
    self.session = session
    self.stats = stats
    self.layer = layer
    pictureView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    super.init()

    window.title = "UmbelPlay"
    window.collectionBehavior = [.fullScreenPrimary]
    window.center()
    layer.framebufferOnly = true
    let container = NSView(frame: window.contentView?.bounds ?? .zero)
    // Black where no picture is: around the placeholder picture in picture
    // leaves in the window's middle.
    container.wantsLayer = true
    container.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
    pictureView.frame = container.bounds
    pictureView.wantsLayer = true
    pictureView.layer = layer
    pictureView.autoresizingMask = [.width, .height]
    container.addSubview(pictureView)
    window.contentView = container
    fitDrawable()
    // Moved to a screen of another scale, the window keeps its size in
    // points but not in pixels.
    NotificationCenter.default.addObserver(
      self, selector: #selector(backingChanged),
      name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    // Resized, or into full screen and out: the drawable follows the view.
    NotificationCenter.default.addObserver(
      self, selector: #selector(backingChanged),
      name: NSWindow.didResizeNotification, object: window)
  }

  /// Standard input's window commands: `fullscreen` into full screen or out
  /// of it, `size <width> <height>` the picture's size in points.
  func command(_ words: [String]) {
    switch words.first {
    case "fullscreen":
      window.toggleFullScreen(nil)
      print("command: fullscreen")
    case "size":
      guard words.count == 3, let width = Double(words[1]), let height = Double(words[2]) else {
        print("usage: size <width> <height>")
        break
      }
      window.setContentSize(NSSize(width: width, height: height))
      print("command: size \(Int(width))×\(Int(height))")
    default:
      break
    }
    fflush(stdout)
  }

  /// The renderer draws at the drawable's size, subtitles included; keeping
  /// it at the view's pixel size is what keeps text sharp.
  private func fitDrawable() {
    let scale = window.backingScaleFactor
    let size = window.contentView?.bounds.size ?? .zero
    layer.contentsScale = scale
    layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
  }

  @objc private func backingChanged(_ notification: Notification) {
    fitDrawable()
  }

  /// A half of the screen, for two players side by side.
  enum Side: String {
    case left, right

    static var fromEnvironment: Side? {
      ProcessInfo.processInfo.environment["UMBEL_WINDOW"].flatMap(Side.init(rawValue:))
    }
  }

  func show() {
    if let side = Side.fromEnvironment, let visible = NSScreen.main?.visibleFrame {
      let size = window.frame.size
      let x = side == .left ? visible.minX : visible.maxX - size.width
      window.setFrameOrigin(NSPoint(x: x, y: visible.midY - size.height / 2))
    }
    // UMBEL_BACKGROUND=1: shown without taking the keyboard, for scripted
    // runs while someone keeps typing elsewhere; a stray key would steer it.
    if ProcessInfo.processInfo.environment["UMBEL_BACKGROUND"] == "1" {
      window.orderFrontRegardless()
      return
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func startDisplayLoop() {
    var link: CVDisplayLink?
    CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard let link else { return }
    displayLink = link

    let context = Unmanaged.passUnretained(self).toOpaque()
    CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
      guard let userInfo else { return kCVReturnSuccess }
      let window = Unmanaged<PlayerWindow>.fromOpaque(userInfo).takeUnretainedValue()
      window.tick()
      return kCVReturnSuccess
    }, context)
    CVDisplayLinkStart(link)
  }

  func stopDisplayLoop() {
    if let displayLink { CVDisplayLinkStop(displayLink) }
    displayLink = nil
  }

  /// Seeking from the keyboard.
  ///
  /// Checking by hand calls for dragging the progress bar a dozen times, and
  /// this example has none; keys are an equivalent that will do and costs
  /// least. Holding an arrow key makes seeks in quick succession, which puts
  /// the core's "only the last one counts" to the test.
  func startKeyboardControl(duration: CMTime) {
    let session = self.session
    let total = duration.isValid && !duration.isIndefinite ? duration.seconds : 0
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      switch event.keyCode {
      case 123:   // ←
        self.nudge(by: -10, total: total)
        return nil
      case 124:   // →
        self.nudge(by: 10, total: total)
        return nil
      case 49:    // space
        Task { await Self.toggle(session, stats: self.stats) }
        return nil
      default:
        break
      }
      if event.charactersIgnoringModifiers == "a" {
        self.cycleAudioTrack()
        return nil
      }
      if event.charactersIgnoringModifiers == "s" {
        self.cycleSubtitleTrack()
        return nil
      }
      if event.charactersIgnoringModifiers == "p", let toggle = self.onPictureInPicture {
        toggle()
        return nil
      }
      // Number keys go to that tenth of the way.
      if total > 0,
         let text = event.charactersIgnoringModifiers,
         let digit = Int(text), (0...9).contains(digit) {
        self.seek(to: total * Double(digit) / 10)
        return nil
      }
      return event
    }
  }

  func stopKeyboardControl() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }

  /// Adds to or subtracts from the target built up, not the clock.
  private func nudge(by delta: Double, total: Double) {
    let session = self.session
    Task { [weak self] in
      guard let self else { return }
      // What follows ?? is an autoclosure that cannot await; spelled out.
      let stored = await self.desiredSeconds
      let base: Double
      if let stored {
        base = stored
      } else {
        base = await session.currentTime.seconds
      }
      var target = base + delta
      if target < 0 { target = 0 }
      if total > 0, target > total { target = total }
      await self.setDesired(target)
      await self.stats.markSeeked()
      try? await session.seek(to: CMTime(seconds: target, preferredTimescale: 600))
      await self.clearDesired(ifStillAt: target)
    }
  }

  private func seek(to seconds: Double) {
    let session = self.session
    Task { [weak self] in
      await self?.setDesired(seconds)
      await self?.stats.markSeeked()
      try? await session.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
      await self?.clearDesired(ifStillAt: seconds)
    }
  }

  /// Cycles through off and every subtitle track, external ones included.
  private func cycleSubtitleTrack() {
    let session = self.session
    Task {
      let tracks = await session.tracks.filter { $0.kind == .subtitle }
      guard !tracks.isEmpty else {
        print("no subtitle tracks")
        return
      }
      let choices: [UmbelTrack?] = [nil] + tracks
      let current = await session.selectedSubtitleTrack
      let index = choices.firstIndex { $0?.id == current } ?? 0
      let next = choices[(index + 1) % choices.count]
      do {
        try await session.selectSubtitleTrack(next?.id)
        if let next {
          print("subtitles: [\(next.id.rawValue)] \(next.codecName)"
                + (next.language.map { " (\($0))" } ?? "")
                + (next.isExternal ? " external" : ""))
        } else {
          print("subtitles: off")
        }
      } catch {
        print("switching subtitles failed: \(error.localizedDescription)")
      }
    }
  }

  /// Cycles through the audio tracks. For checking by hand: the picture
  /// should not move a hair as it switches.
  private func cycleAudioTrack() {
    let session = self.session
    Task {
      let tracks = await session.tracks.filter { $0.kind == .audio }
      guard tracks.count > 1 else { return }
      let current = await session.selectedAudioTrack
      let index = tracks.firstIndex { $0.id == current } ?? 0
      let next = tracks[(index + 1) % tracks.count]
      try? await session.selectAudioTrack(next.id)
      print("audio track [\(next.id.rawValue)] \(next.codecName)"
            + (next.language.map { " (\($0))" } ?? ""))
    }
  }

  private func setDesired(_ seconds: Double) { desiredSeconds = seconds }

  /// Cleared only if no newer press came in, or the later target would be
  /// lost.
  private func clearDesired(ifStillAt seconds: Double) {
    if desiredSeconds == seconds { desiredSeconds = nil }
  }

  private static func toggle(_ session: PlaybackSession, stats: PlaybackStats) async {
    // Buffering is still wanting to play; the space bar pauses it too.
    let phase = await session.phase
    if phase == .playing || phase == .buffering {
      await stats.markPaused()
      await session.pause()
    } else {
      try? await session.play()
    }
  }

  /// The display callback runs on its own thread, so this cannot be main
  /// actor isolated. It touches `session`, a Sendable let, alone, and hands
  /// the work on without blocking here.
  private nonisolated func tick() {
    Task { [session, stats] in
      guard await stats.beginPresent() else { return }
      // Clock first, then present: taken side by side, the difference is the
      // picture's real offset from the clock.
      let now = await session.currentTime
      // try? and the optional result fold into one level; bind once.
      if let shown = try? await session.renderVideoFrame() {
        await stats.record(
          frameTime: shown.presentationTime, clock: now, droppedFrames: shown.droppedFrames)
      }
      await stats.endPresent()
    }
  }
}
