import CoreMedia
import Foundation

/// A position played and the host time it was played at.
public struct RenderAnchor: Sendable, Equatable {
  /// How far into the content has been played.
  public let mediaTime: CMTime
  /// The host clock's reading at that moment.
  public let hostTime: CMTime

  public init(mediaTime: CMTime, hostTime: CMTime) {
    self.mediaTime = mediaTime
    self.hostTime = hostTime
  }
}

/// Told of every change of the clock's anchor or rate, as it happens: what
/// it is given places the clock exactly — `now = anchor media time + (host
/// time − anchor host time) × rate`. A renderer that times its own display
/// follows the clock this way; the session connects a video renderer that
/// is one. Called on the clock's executor, and must not wait.
public protocol ClockFollower: Sendable {
  func clockDidChange(anchor: RenderAnchor, rate: Double)
}

/// The one authority on audio/video sync.
///
/// Not a counter ticking by itself but an anchor and interpolation:
///
///     now() = anchor media time + (host time now - anchor host time) × rate
///
/// The audio output makes a new anchor with each batch it plays, and the
/// pipeline adopts it; between anchors the host time interpolates. Without
/// sound, anchors are set only at the start and at seeks, and `now()` is
/// simply a linear function of host time — no second code path.
///
/// On the system's timeline (`SystemTimeline`) the system does that
/// interpolation: `now()` reads the timeline, and every change of rate or
/// position is set on it.
public actor PresentationClock {
  /// Where time comes from.
  public enum Authority: String, Sendable, Equatable {
    case audio
    case host
    /// The system's render synchronizer keeps the time; see `SystemTimeline`.
    case system
  }

  private let hostTime: HostTimeSource
  private let follower: (any ClockFollower)?
  private let timeline: (any SystemTimeline)?
  private let diagnostics: UmbelPlaybackDiagnostics?
  private var anchor: RenderAnchor {
    didSet { follower?.clockDidChange(anchor: anchor, rate: currentRate) }
  }
  private var currentRate: Double = 0
  private var currentAuthority: Authority = .host
  /// Stopped on the end of playback; until a seek, nothing moves it.
  private var isStoppedAtEnd = false

  public init(
    hostTime: HostTimeSource, follower: (any ClockFollower)? = nil,
    diagnostics: UmbelPlaybackDiagnostics?
  ) {
    self.init(hostTime: hostTime, follower: follower, timeline: nil, diagnostics: diagnostics)
  }

  public init(hostTime: HostTimeSource, follower: (any ClockFollower)? = nil) {
    self.init(hostTime: hostTime, follower: follower, diagnostics: nil)
  }

  /// On the system's timeline: `now()` reads it, and every change of rate or
  /// position is set on it. Anchors from an output have no say then.
  internal init(
    hostTime: HostTimeSource, follower: (any ClockFollower)?, timeline: (any SystemTimeline)?,
    diagnostics: UmbelPlaybackDiagnostics? = nil
  ) {
    self.hostTime = hostTime
    self.follower = follower
    self.timeline = timeline
    self.diagnostics = diagnostics
    self.anchor = RenderAnchor(mediaTime: .zero, hostTime: hostTime.now)
    if timeline != nil { currentAuthority = .system }
  }

  public var authority: Authority { currentAuthority }
  public var rate: Double { currentRate }

  /// The present position.
  public func now() -> CMTime {
    if let timeline { return timeline.time }
    guard currentRate != 0 else { return anchor.mediaTime }
    let elapsed = CMTimeSubtract(hostTime.now, anchor.hostTime)
    let scaled = CMTimeMultiplyByFloat64(elapsed, multiplier: currentRate)
    return CMTimeAdd(anchor.mediaTime, scaled)
  }

  /// 0 pauses; otherwise how many seconds of media a second of host time
  /// covers — 2 plays twice as fast.
  ///
  /// The old rate is settled up to now and the anchor reset before changing
  /// it; otherwise time spent paused would count. On a system timeline, now
  /// is where its last seek goes, until it gets there: settled where it
  /// stood, a rate change undid the seek.
  public func setRate(_ rate: Double) {
    let settled = timeline?.handoverTime ?? now()
    let oldRate = currentRate
    currentRate = rate
    anchor = RenderAnchor(mediaTime: settled, hostTime: hostTime.now)
    timeline?.setRate(rate)
    diagnostics?.record("clock_rate", values: [
      "position": settled.seconds, "oldRate": oldRate, "rate": rate,
      "anchorMedia": anchor.mediaTime.seconds, "anchorHost": anchor.hostTime.seconds],
      labels: ["authority": currentAuthority.rawValue])
  }

  /// A new anchor after a seek. The clock should **jump**, not creep towards
  /// the new position.
  public func reset(to time: CMTime) {
    anchor = RenderAnchor(mediaTime: time, hostTime: hostTime.now)
    isStoppedAtEnd = false
    timeline?.set(rate: currentRate, time: time)
    diagnostics?.record("clock_reset", values: [
      "position": time.seconds, "rate": currentRate, "anchorHost": anchor.hostTime.seconds])
  }

  /// Stops on the end of playback, and stays there until a seek: the output
  /// reports where it got to, which is not always the end — sound can end
  /// before the picture — and a host refreshing the clock after the end
  /// would otherwise pull it back.
  internal func stop(at end: CMTime) {
    anchor = RenderAnchor(mediaTime: end, hostTime: hostTime.now)
    isStoppedAtEnd = true
    timeline?.set(rate: 0, time: end)
    diagnostics?.record("clock_end", values: ["position": end.seconds])
  }

  /// Adopts a new anchor from the audio output.
  ///
  /// Not public on purpose: only the engine moves the state on. If other
  /// modules could move time, sync would have no single authority.
  internal func adopt(_ newAnchor: RenderAnchor) {
    guard timeline == nil, !isStoppedAtEnd else {
      diagnostics?.record("clock_anchor_ignored", values: ["anchorMedia": newAnchor.mediaTime.seconds],
                          labels: ["reason": timeline != nil ? "systemTimeline" : "ended"])
      return
    }
    let before = diagnostics == nil ? CMTime.invalid : now()
    anchor = newAnchor
    if let diagnostics {
      let after = now()
      diagnostics.record("clock_adopt", values: [
        "positionBefore": before.seconds, "positionAfter": after.seconds,
        "correction": (after - before).seconds, "rate": currentRate,
        "anchorMedia": newAnchor.mediaTime.seconds, "anchorHost": newAnchor.hostTime.seconds,
        "anchorAge": (hostTime.now - newAnchor.hostTime).seconds],
        labels: ["authority": currentAuthority.rawValue])
    }
  }

  /// Set by the pipeline once loaded: audio with a sound track, host
  /// without.
  internal func setAuthority(_ authority: Authority) {
    guard timeline == nil else { return }
    currentAuthority = authority
  }
}
