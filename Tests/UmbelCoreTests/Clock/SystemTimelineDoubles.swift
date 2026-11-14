import AVFoundation
import CoreMedia
import Foundation
@testable import UmbelCore

/// A host clock moved by hand.
final class TimelineHostTime: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    seconds += delta
    lock.unlock()
  }
}

/// A system timeline driven by a host clock moved by hand: it runs from
/// where it was last set, at the rate set, and records every setting and
/// every renderer put on it or taken off.
final class TimelineDouble: SystemTimeline, @unchecked Sendable {
  struct Setting: Equatable {
    let rate: Double
    let time: Double
    let host: Double
  }

  private let lock = NSLock()
  private let host: any HostTimeSource
  private var current = Setting(rate: 0, time: 0, host: 0)
  private var recorded: [Setting] = []
  private var rateOnly: [Double] = []
  private var on: [ObjectIdentifier] = []
  /// Renderers are refused, as the system refuses a layer with a timebase.
  var refusesRenderers = false

  init(host: any HostTimeSource) {
    self.host = host
  }

  var time: CMTime {
    let setting = locked { current }
    let elapsed = host.now.seconds - setting.host
    return CMTime(seconds: setting.time + elapsed * setting.rate, preferredTimescale: 1_000_000)
  }

  var sets: [Setting] { locked { recorded } }
  var rateOnlySets: [Double] { locked { rateOnly } }

  /// Set when called, by the host clock of that moment.
  func set(rate: Double, time: CMTime) {
    let hostTime = host.now
    locked {
      current = Setting(rate: rate, time: time.seconds, host: hostTime.seconds)
      recorded.append(current)
    }
  }

  func setRate(_ rate: Double) {
    let hostTime = host.now
    locked {
      let elapsed = hostTime.seconds - current.host
      let standing = current.time + elapsed * current.rate
      current = Setting(rate: rate, time: standing, host: hostTime.seconds)
      rateOnly.append(rate)
    }
  }

  func add(_ renderer: QueuedRenderer) throws {
    if refusesRenderers { throw NSError(domain: "TimelineDouble", code: 1) }
    locked { on.append(ObjectIdentifier(renderer.renderer)) }
  }

  func remove(_ renderer: QueuedRenderer) async {
    locked { on.removeAll { $0 == ObjectIdentifier(renderer.renderer) } }
  }

  /// Whether `renderer` is on the timeline now.
  func holds(_ renderer: any AVQueuedSampleBufferRendering) -> Bool {
    locked { on.contains(ObjectIdentifier(renderer)) }
  }

  var rendererCount: Int { locked { on.count } }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

/// An audio renderer that records what it holds. `discard()` stands for the
/// system dropping it all on its own, as on a change of output device.
final class AudioRendererDouble: AudioSampleRendering, @unchecked Sendable {
  let queued = QueuedRenderer(renderer: AVSampleBufferAudioRenderer())
  private let lock = NSLock()
  private let onDiscarded: @Sendable () -> Void
  private var held: [Double] = []
  private var lengths: [Int] = []
  private var flushes = 0
  private var ready = true
  private var failed = false

  init(onDiscarded: @escaping @Sendable () -> Void) {
    self.onDiscarded = onDiscarded
  }

  /// Presentation times of what it holds, in the order handed over.
  var holding: [Double] { locked { held } }
  /// How many samples each held buffer has, in the same order.
  var holdingLengths: [Int] { locked { lengths } }
  var flushCount: Int { locked { flushes } }
  var isReady: Bool {
    get { locked { ready } }
    set { locked { ready = newValue } }
  }
  var fails: Bool {
    get { locked { failed } }
    set { locked { failed = newValue } }
  }

  var isReadyForMoreMediaData: Bool { isReady }
  var hasFailed: Bool { fails }
  var failure: String? { fails ? "the double's reason" : nil }
  private var level: (volume: Float, muted: Bool) = (1, false)
  var volume: Float {
    get { locked { level.volume } }
    set { locked { level.volume = newValue } }
  }
  var isMuted: Bool {
    get { locked { level.muted } }
    set { locked { level.muted = newValue } }
  }
  func enqueue(_ buffer: CMSampleBuffer) {
    locked {
      held.append(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
      lengths.append(CMSampleBufferGetNumSamples(buffer))
    }
  }
  func flush() { locked { held.removeAll(); lengths.removeAll(); flushes += 1 } }

  func discard() {
    locked { held.removeAll(); lengths.removeAll() }
    onDiscarded()
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

/// Makes the output's renderers, and keeps them for the test to look at.
final class RendererMaker: @unchecked Sendable {
  private let lock = NSLock()
  private var renderers: [AudioRendererDouble] = []

  var made: [AudioRendererDouble] {
    lock.lock()
    defer { lock.unlock() }
    return renderers
  }

  func make(_ onDiscarded: @escaping @Sendable () -> Void) -> any AudioSampleRendering {
    let renderer = AudioRendererDouble(onDiscarded: onDiscarded)
    lock.lock()
    renderers.append(renderer)
    lock.unlock()
    return renderer
  }
}

/// A display layer's place: joins and leaves timelines as the real one
/// does, and takes whatever it is given.
final class JoiningSink: SampleBufferSink, @unchecked Sendable {
  let layer = AVSampleBufferDisplayLayer()
  private let lock = NSLock()
  private var count = 0
  /// How many samples it was given.
  var receivedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func enqueue(_ buffer: CMSampleBuffer) {
    lock.lock()
    count += 1
    lock.unlock()
  }
  func flush() {}
  var hasFailed: Bool { false }
  var isReadyForMoreMediaData: Bool { true }

  func join(_ timeline: any SystemTimeline, replacing own: CMTimebase) async throws {
    try timeline.add(QueuedRenderer(renderer: layer))
  }

  func leave(_ timeline: any SystemTimeline, restoring own: CMTimebase) async {
    await timeline.remove(QueuedRenderer(renderer: layer))
  }
}
