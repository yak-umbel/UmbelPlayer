import AVFoundation
import CoreMedia
import Foundation
import UmbelObjCSupport

/// The system's own clock for playback: what its render synchronizer keeps.
///
/// With one, the session's clock reads its time rather than working it out,
/// and sets it rather than keeping its own. Sound and the system's display
/// layers go on it too, so all of them run on one timeline, the system's:
/// it holds a start back until sound really comes out, and accounts for the
/// device's latency and drift.
internal protocol SystemTimeline: AnyObject, Sendable {
  /// The media time now.
  var time: CMTime { get }
  /// The accepted seek target while a seek is pending, otherwise the current
  /// time. A replacement timeline must preserve the most recent control.
  var handoverTime: CMTime { get }
  /// Runs at `rate` from `time`. From standing, the system starts it once
  /// the sound really comes out, not at once.
  func set(rate: Double, time: CMTime)
  /// Changes only the rate, preserving the timeline's current or accepted
  /// position. A seek or handover must use `set(rate:time:)` instead.
  func setRate(_ rate: Double)
  /// Puts a renderer on the timeline: it then plays or shows what it is
  /// given by this time. Throws, rather than bringing the process down, for
  /// one the system will not take — a display layer with a timebase of its
  /// own, or one still on another timeline.
  func add(_ renderer: QueuedRenderer) throws
  /// Takes it off again; returns once the system has.
  func remove(_ renderer: QueuedRenderer) async
}

internal extension SystemTimeline {
  var handoverTime: CMTime { time }
}

/// A renderer reference carried between threads for timeline membership.
/// This does not change its isolation: display-layer properties must still
/// be accessed on the main actor.
internal struct QueuedRenderer: @unchecked Sendable {
  let renderer: any AVQueuedSampleBufferRendering
}

/// A renderer whose pictures can go on a session's system timeline.
internal protocol SystemTimelineJoining: Sendable {
  func join(_ timeline: any SystemTimeline) async throws
  func leave() async
}

/// The real one: a render synchronizer.
internal final class SynchronizerTimeline: SystemTimeline, @unchecked Sendable {
  let synchronizer = AVSampleBufferRenderSynchronizer()
  private let diagnosticLock = NSLock()
  private var diagnostics: UmbelPlaybackDiagnostics?
  private var lastDiagnosticHost = -Double.infinity

  var time: CMTime {
    let time = synchronizer.currentTime()
    recordClock(time, event: "system_clock_read")
    return time
  }

  private func recordClock(
    _ read: CMTime, event: String, target: CMTime? = nil, force: Bool = false
  ) {
    let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let recorder = diagnosticLock.withLock { () -> UmbelPlaybackDiagnostics? in
      guard let diagnostics else { return nil }
      if target == nil, !force {
        guard host - lastDiagnosticHost >= 1 else { return nil }
        lastDiagnosticHost = host
      }
      return diagnostics
    }
    guard let recorder else { return }
    let timebase = synchronizer.timebase
    let renderers = synchronizer.renderers
    var values: [String: Double] = [
      "readTime": read.seconds, "timebaseTime": CMTimebaseGetTime(timebase).seconds,
      "timebaseRate": CMTimebaseGetRate(timebase), "effectiveRate": CMTimebaseGetEffectiveRate(timebase),
      "requestedRate": Double(synchronizer.rate), "rendererCount": Double(renderers.count),
    ]
    if let target { values["targetTime"] = target.seconds }
    var labels: [String: String] = [:]
    for (index, renderer) in renderers.enumerated() {
      let key = "renderer\(index)"
      labels[key] = String(describing: type(of: renderer))
      values[key + "Ready"] = renderer.isReadyForMoreMediaData ? 1 : 0
      values[key + "Sufficient"] = renderer.hasSufficientMediaDataForReliablePlaybackStart ? 1 : 0
    }
    recorder.record(event, values: values, labels: labels)
  }

  /// Without a host time, so the synchronizer waits for its renderers to
  /// have enough before it starts. Given one — "now" — it started at once,
  /// ahead of the sound by the output's latency, and a film's first words
  /// went unheard.
  func set(rate: Double, time: CMTime) {
    synchronizer.setRate(Float(rate), time: time)
    recordClock(synchronizer.currentTime(), event: "system_clock_set", target: time)
  }

  func setRate(_ rate: Double) {
    guard rate.isFinite, Float(rate).isFinite else { return }
    synchronizer.setRate(Float(rate), time: .invalid)
    recordClock(synchronizer.currentTime(), event: "system_clock_set", force: true)
  }

  func add(_ renderer: QueuedRenderer) throws {
    let synchronizer = self.synchronizer
    var failure: NSError?
    guard UmbelCatchingObjCException({ synchronizer.addRenderer(renderer.renderer) }, &failure) else {
      throw failure ?? NSError(domain: "UmbelSystemTimeline", code: 1)
    }
  }

  func remove(_ renderer: QueuedRenderer) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      synchronizer.removeRenderer(renderer.renderer, at: .invalid) { _ in done.resume() }
    }
  }
}

extension SynchronizerTimeline: PlaybackDiagnosticsReceiving {
  func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) {
    diagnosticLock.withLock {
      self.diagnostics = diagnostics
      lastDiagnosticHost = -.infinity
    }
  }
}
