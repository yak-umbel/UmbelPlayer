import CoreMedia
import UmbelCore

/// What picture in picture's window asks of playback, and what it tells it,
/// kept apart from the system's controller so it can be checked without one.
///
/// The window asks on the main thread and wants an answer at once, while a
/// session answers asynchronously: whether it is paused and how long it is
/// come from a copy, refreshed twice a second while the window is open and
/// at once after anything done from it.
@MainActor
public final class PictureInPicturePlayback {
  public let session: PlaybackSession
  public let renderer: SwitchingVideoRenderer
  public private(set) var isPaused = true
  public private(set) var duration = CMTime.indefinite
  /// Told when `isPaused` changes: the window's buttons are drawn again.
  var onChange: (() -> Void)?
  private var watching: Task<Void, Never>?

  public init(session: PlaybackSession, renderer: SwitchingVideoRenderer) {
    self.session = session
    self.renderer = renderer
  }

  /// What the window's progress bar spans.
  public var timeRange: CMTimeRange { Self.timeRange(forDuration: duration) }

  /// The whole film; a live stream, which has no end, open both ways — as
  /// the system asks for one.
  nonisolated static func timeRange(forDuration duration: CMTime) -> CMTimeRange {
    guard duration.isNumeric, duration > .zero else {
      return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    return CMTimeRange(start: .zero, duration: duration)
  }

  public func setPlaying(_ playing: Bool) async {
    setPaused(!playing)
    if playing {
      try? await session.play()
    } else {
      await session.pause()
    }
  }

  /// The window's skip buttons: on or back from where it is. The session
  /// holds a seek to the start and to the end.
  public func skip(by interval: CMTime) async {
    try? await session.seek(to: CMTimeAdd(await session.currentTime, interval))
  }

  /// The window is opening: the picture goes to it.
  public func started() async {
    await renderer.show(.pictureInPicture)
    watching?.cancel()
    watching = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }
  }

  /// The window has closed: the picture goes back.
  public func stopped() async {
    watching?.cancel()
    watching = nil
    await renderer.show(.main)
    await renderer.setPictureInPictureRenderSize(nil)
  }

  /// Takes the session's state afresh. Waiting to play counts as playing:
  /// the window's button should offer to pause.
  public func refresh() async {
    duration = await session.duration
    let phase = await session.phase
    setPaused(!(phase == .playing || phase == .buffering))
  }

  private func setPaused(_ paused: Bool) {
    guard paused != isPaused else { return }
    isPaused = paused
    onChange?()
  }
}
