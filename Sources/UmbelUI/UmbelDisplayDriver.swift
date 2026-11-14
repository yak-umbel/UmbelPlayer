#if os(iOS)
import Foundation
import QuartzCore
import UIKit
import UmbelCore

/// Drives foreground presentation from a display link on its own RunLoop,
/// and picture in picture's in the background too, from a timer there.
/// Construct and control it on the main actor, after configuring the layers.
/// To switch to manual `renderVideoFrame()` calls, stop the driver and wait
/// until `statistics.isRendering` is false. Do not drive both paths at once.
@MainActor
public final class UmbelDisplayDriver {
  private let coordinator: DisplayTickCoordinator
  private nonisolated(unsafe) var worker: DisplayLinkWorker?
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
  private var drawableAvailable = true
  private var foreground = true
  private var pictureInPictureActive = false

  public init(session: PlaybackSession) {
    coordinator = DisplayTickCoordinator { try await session.renderVideoFrame() }
  }

  internal init(render: @escaping @Sendable () async throws -> PresentedFrame?) {
    coordinator = DisplayTickCoordinator(render: render)
  }

  /// Starts an optional foreground loop. Repeated calls have no effect.
  public func start() {
    guard worker == nil else { return }
    foreground = UIApplication.shared.applicationState != .background
    let worker = DisplayLinkWorker(coordinator: coordinator)
    self.worker = worker
    updateRenderingState()
    worker.start(paused: !isRendering, usesTimer: !foreground)
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                         object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setForeground(false) }
      },
      center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                         object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setForeground(true) }
      },
    ]
  }

  /// Stops callbacks and cancels pending render work. A render operation
  /// already in progress may finish, but cannot record into a later run.
  public func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    coordinator.stop()
    worker?.stop()
    worker = nil
  }

  /// Call from view attachment changes; a detached or drawable-less view
  /// must not ask its Metal renderer to draw. Foreground pause keeps the
  /// driver alive for subtitle changes and paused-frame redraws.
  public func setDrawableAvailable(_ available: Bool) {
    drawableAvailable = available
    updateRenderingState()
  }

  /// Picture in picture's small window shows what is drawn for it, in the
  /// foreground without the view's drawable and in the background too —
  /// where the display link does not fire, so a timer drives it, about
  /// sixty times a second. `UmbelPictureInPicture` given this driver as its
  /// `displayDriver` says when it opens and closes.
  public func setPictureInPictureActive(_ active: Bool) {
    pictureInPictureActive = active
    updateRenderingState()
  }

  public var statistics: UmbelDisplayStatistics { coordinator.snapshot }

  private func setForeground(_ value: Bool) {
    foreground = value
    updateRenderingState()
  }

  /// A detached view's renderer must not draw; picture in picture's, shown
  /// by the system, may. In the background only picture in picture draws.
  private var isRendering: Bool {
    pictureInPictureActive || (foreground && drawableAvailable)
  }

  private func updateRenderingState() {
    guard let worker else { return }
    if isRendering { coordinator.start() }
    else { coordinator.stop() }
    worker.setMode(paused: !isRendering, usesTimer: !foreground)
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
    coordinator.stop()
    worker?.stop()
  }
}

/// Objective-C callbacks and all display-link mutations stay on this thread.
private final class DisplayLinkWorker: NSObject, @unchecked Sendable {
  private let lock = NSLock()
  private let coordinator: DisplayTickCoordinator
  private var thread: Thread?
  private var stopped = false
  private var shouldPause = false
  private var usesTimer = false
  private var link: CADisplayLink?
  private var timer: Timer?

  init(coordinator: DisplayTickCoordinator) { self.coordinator = coordinator }

  func start(paused: Bool, usesTimer: Bool) {
    lock.withLock {
      shouldPause = paused
      self.usesTimer = usesTimer
    }
    let thread = Thread { [self] in run() }
    thread.name = "UmbelDisplayDriver"
    thread.qualityOfService = .userInteractive
    self.thread = thread
    thread.start()
  }

  /// Requests are queued under the lock that run() takes to clear `thread`
  /// on its way out. One queued after that, for a thread already finished,
  /// would never run and would keep this worker, and with it the render
  /// closure, alive.
  func setMode(paused: Bool, usesTimer: Bool) {
    lock.withLock {
      shouldPause = paused
      self.usesTimer = usesTimer
      guard !stopped, let thread else { return }
      perform(#selector(applyPause), on: thread, with: nil, waitUntilDone: false,
              modes: [RunLoop.Mode.common.rawValue])
    }
  }

  func stop() {
    lock.withLock {
      stopped = true
      guard let thread else { return }
      perform(#selector(halt), on: thread, with: nil, waitUntilDone: false,
              modes: [RunLoop.Mode.common.rawValue])
    }
  }

  private func run() {
    defer {
      link?.invalidate()
      link = nil
      timer?.invalidate()
      timer = nil
      lock.withLock { thread = nil }
    }
    guard !lock.withLock({ stopped }) else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    self.link = link
    link.add(to: .current, forMode: .common)
    applyPause()
    // RunLoop.run() repeats its passes for as long as any source is attached,
    // and halt's CFRunLoopStop ends only the current pass; so run one pass at
    // a time until stop() has been called. The display link, paused or not,
    // stays attached until halt, so a pass waits rather than spins. Every
    // source here is added for the common modes, which include the default.
    while !lock.withLock({ stopped }) {
      RunLoop.current.run(mode: .default, before: .distantFuture)
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    coordinator.tick(at: CACurrentMediaTime())
  }

  /// The display link in the foreground, the timer in the background: one
  /// of them, or neither while paused.
  @objc private func applyPause() {
    let (paused, timed) = lock.withLock { (stopped || shouldPause, usesTimer) }
    link?.isPaused = paused || timed
    guard !paused, timed else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard timer == nil else { return }
    let made = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      self?.coordinator.tick(at: CACurrentMediaTime())
    }
    RunLoop.current.add(made, forMode: .common)
    timer = made
  }

  @objc private func halt() {
    link?.invalidate()
    timer?.invalidate()
    timer = nil
    CFRunLoopStop(CFRunLoopGetCurrent())
  }
}
#endif
