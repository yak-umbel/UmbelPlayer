import AVFoundation
import CoreMedia
import Foundation
import UmbelObjCSupport

/// The system audio player's clock expressed in the film's time:
/// item time - fragment timestamp shift + audio delay.
/// Controls and callbacks share a lock; player mutations run on the main queue
/// as required by the oldest supported systems. Time reads never wait for it.
/// This adapter owns the player, its pending seeks and the attached display layers.
internal final class PlayerItemTimeline: SystemTimeline, @unchecked Sendable {
  let player: AVPlayer
  private let shift: CMTime
  // Cancelling a seek may call its completion while a control operation runs.
  private let lock = NSRecursiveLock()
  private var delay: CMTime = .zero
  private var generation: UInt64 = 0
  private var pendingItemTime: CMTime?
  /// A seek of ours has landed: the place the item reports is where it
  /// plays. Before, it is only what the playlist asked for; the player may
  /// start from the segment's first frame instead.
  private var hasLanded = false
  private var closed = false
  private var closedTime: CMTime = .zero
  private var level: (volume: Float, muted: Bool) = (1, false)
  private var rate: Double = 0
  /// Where the sound ended and when, once it has: the time runs on from
  /// there at the rate, as the synchronizer's does without sound. The
  /// picture can end later, and must still be shown and ended. Display
  /// layers follow the item's clock, which stops there.
  private var pastEnd: (film: CMTime, host: CMTime)?
  private var endObserver: NSObjectProtocol?
  private var displayTimebase: CMTimebase?
  private var layers: [AVSampleBufferDisplayLayer] = []

  init(url: URL, shift: CMTime) {
    precondition(shift.isNumeric)
    self.shift = shift
    player = AVPlayer(url: url)
    #if !os(visionOS)
    // The loopback address is only reachable on this device.
    player.allowsExternalPlayback = false
    #endif
    // As the engine's own renderer: a changed speed sounds the same whichever
    // way the sound goes, and after a fallback.
    player.currentItem?.audioTimePitchAlgorithm = .spectral
    // Left alone it asks for the whole track at once, while reading here
    // keeps pace with the picture. Six seconds keeps it asking for a segment
    // at a time, six to eight seconds ahead.
    player.currentItem?.preferredForwardBufferDuration = Self.forwardBuffer
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: nil
    ) { [weak self] _ in self?.soundEnded() }
  }

  static let forwardBuffer: TimeInterval = 6

  /// Where a pending seek goes, until it gets there: the synchronizer's
  /// time is a new one at once too. Its item's clock stays where it was for
  /// a moment, and pictures timed by it took the new ones for late.
  var time: CMTime { handoverTime }

  /// Past where the sound ends, the time running on without it.
  var isPastSoundEnd: Bool {
    lock.withLock { pastEnd != nil }
  }

  /// A seek asked for has not landed yet.
  var isSeeking: Bool {
    lock.withLock { !closed && pendingItemTime != nil }
  }

  /// The rate last asked for: the player's own falls to 0 when it cannot
  /// play, without a word.
  var requestedRate: Double {
    lock.withLock { closed ? 0 : rate }
  }

  var handoverTime: CMTime {
    lock.withLock {
      if closed { return closedTime }
      if let pendingItemTime { return CMTimeAdd(CMTimeSubtract(pendingItemTime, shift), delay) }
      return filmTime()
    }
  }

  func set(rate: Double, time: CMTime) {
    guard rate.isFinite, Float(rate).isFinite, time.isNumeric else { return }
    lock.withLock {
      guard !closed else { return }
      let standing = filmTime()
      self.rate = rate
      generation &+= 1
      let requestedGeneration = generation
      let itemTime = CMTimeSubtract(CMTimeAdd(time, shift), delay)
      // Where it stands, with no seek on the way, only the rate changes: a
      // seek flushes the sound, which the player's own pause and play fade.
      // Seeking each time, the speakers clicked.
      if hasLanded, pendingItemTime == nil, abs(CMTimeSubtract(time, standing).seconds) < Self.samePlace {
        // Past the sound's end the player is done: the time alone goes on.
        if pastEnd != nil {
          pastEnd = (standing, Self.hostNow())
          return
        }
        Self.onMain { [weak self] in
          guard let self else { return }
          lock.withLock {
            guard !closed, generation == requestedGeneration else { return }
            if self.rate == 0 { player.pause() } else { player.rate = Float(self.rate) }
          }
        }
        return
      }
      pendingItemTime = itemTime
      pastEnd = nil
      Self.onMain { [weak self] in
        guard let self else { return }
        lock.withLock {
          guard !closed, generation == requestedGeneration else { return }
          player.pause()
          player.currentItem?.cancelPendingSeeks()
          player.seek(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Self.onMain { [weak self] in
              guard let self else { return }
              self.lock.withLock {
                guard !self.closed, self.generation == requestedGeneration else { return }
                self.pendingItemTime = nil
                guard finished else { return }
                self.hasLanded = true
                if self.rate == 0 { self.player.pause() } else { self.player.rate = Float(self.rate) }
              }
            }
          }
        }
      }
    }
  }

  /// Changes speed without issuing a second seek. If an initial seek is still
  /// landing, its completion applies the newest requested rate.
  func setRate(_ rate: Double) {
    guard rate.isFinite, Float(rate).isFinite else { return }
    lock.withLock {
      guard !closed else { return }
      let standing = filmTime()
      self.rate = rate
      if pastEnd != nil {
        pastEnd = (standing, Self.hostNow())
        return
      }
      guard pendingItemTime == nil else { return }
      if !hasLanded {
        set(rate: rate, time: standing)
        return
      }
      Self.onMain { [weak self] in
        guard let self else { return }
        lock.withLock {
          guard !closed, pendingItemTime == nil, pastEnd == nil else { return }
          if self.rate == 0 { player.pause() } else { player.rate = Float(self.rate) }
        }
      }
    }
  }

  func setLevel(volume: Float, muted: Bool) {
    guard volume.isFinite else { return }
    lock.withLock {
      guard !closed else { return }
      level = (min(max(volume, 0), 1), muted)
      Self.onMain { [weak self] in
        guard let self else { return }
        lock.withLock {
          guard !closed else { return }
          player.volume = level.volume
          player.isMuted = level.muted
        }
      }
    }
  }

  /// Changes the picture's offset without seeking the audio.
  func setAudioDelay(_ delay: CMTime) {
    guard delay.isNumeric else { return }
    lock.withLock {
      guard !closed else { return }
      self.delay = delay
      if let displayTimebase { align(displayTimebase) }
    }
  }

  /// Attach after the item is ready. A child timebase preserves the film's
  /// timestamp mapping while following the item's stalls, seeks and rate.
  func add(_ renderer: QueuedRenderer) throws {
    // Enter the layer's actor before taking the state lock: main-thread
    // controls may need that lock while a background caller waits here.
    try DisplayLayerAccess.sync {
      try self.addOnMain(renderer)
    }
  }

  @MainActor
  private func addOnMain(_ renderer: QueuedRenderer) throws {
    try lock.withLock {
      guard !closed, let layer = renderer.renderer as? AVSampleBufferDisplayLayer else {
        throw failure("only display layers can join an open audio timeline")
      }
      if layers.contains(where: { $0 === layer }) { return }
      guard layer.controlTimebase == nil else {
        throw failure("the display layer already belongs to a timeline")
      }
      let timebase = try makeDisplayTimebase()
      var error: NSError?
      guard UmbelCatchingObjCException({ layer.controlTimebase = timebase }, &error) else {
        throw error ?? failure("the display layer refused its timebase")
      }
      layers.append(layer)
    }
  }

  func remove(_ renderer: QueuedRenderer) async {
    await MainActor.run {
      lock.withLock {
        guard let layer = renderer.renderer as? AVSampleBufferDisplayLayer,
              layers.contains(where: { $0 === layer }) else { return }
        detach(layer)
        layers.removeAll { $0 === layer }
      }
    }
  }

  func close() {
    lock.withLock {
      guard !closed else { return }
      closedTime = filmTime()
      closed = true
      pendingItemTime = nil
      pastEnd = nil
      endObserver.map(NotificationCenter.default.removeObserver)
      endObserver = nil
      generation &+= 1
      let player = self.player
      let attached = layers.map { QueuedRenderer(renderer: $0) }
      let timebase = displayTimebase
      layers.removeAll()
      displayTimebase = nil
      // Capture resources rather than self, so deinit can use the same cleanup.
      Self.onMain {
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        for renderer in attached {
          guard let layer = renderer.renderer as? AVSampleBufferDisplayLayer,
                let timebase, layer.controlTimebase === timebase else { continue }
          _ = UmbelCatchingObjCException({ layer.controlTimebase = nil }, nil)
        }
        player.replaceCurrentItem(with: nil)
      }
    }
  }

  private func filmTime() -> CMTime {
    if let pastEnd {
      let elapsed = CMTimeSubtract(Self.hostNow(), pastEnd.host)
      return CMTimeAdd(pastEnd.film, CMTimeMultiplyByFloat64(elapsed, multiplier: rate))
    }
    let itemTime = currentItemTime()
    guard itemTime.isNumeric else { return .zero }
    return CMTimeAdd(CMTimeSubtract(itemTime, shift), delay)
  }

  private func currentItemTime() -> CMTime {
    // During startup or a seek, currentTime() can already report the requested
    // position while the playback timebase is still held back for audio.
    player.currentItem?.timebase.map(CMTimebaseGetTime) ?? player.currentTime()
  }

  /// The item played its sound to the end, meant to go on playing.
  private func soundEnded() {
    lock.withLock {
      guard !closed, pendingItemTime == nil, pastEnd == nil, rate != 0 else { return }
      pastEnd = (filmTime(), Self.hostNow())
    }
  }

  private static func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

  /// Closer than this to where it stands is where it stands.
  private static let samePlace = 0.05

  private func makeDisplayTimebase() throws -> CMTimebase {
    if let displayTimebase { return displayTimebase }
    guard let source = player.currentItem?.timebase else {
      throw failure("the audio item's timebase is not ready")
    }
    var made: CMTimebase?
    let result = CMTimebaseCreateWithSourceTimebase(
      allocator: kCFAllocatorDefault, sourceTimebase: source, timebaseOut: &made)
    guard result == noErr, let made else {
      throw failure("could not create the display timebase", code: Int(result))
    }
    align(made)
    displayTimebase = made
    return made
  }

  private func align(_ timebase: CMTimebase) {
    CMTimebaseSetRateAndAnchorTime(
      timebase, rate: 1, anchorTime: CMTimeSubtract(delay, shift), immediateSourceTime: .zero)
  }

  @MainActor
  private func detach(_ layer: AVSampleBufferDisplayLayer) {
    guard let displayTimebase, layer.controlTimebase === displayTimebase else { return }
    _ = UmbelCatchingObjCException({ layer.controlTimebase = nil }, nil)
  }

  private func failure(_ description: String, code: Int = 1) -> NSError {
    NSError(domain: "UmbelAudioTimeline", code: code, userInfo: [NSLocalizedDescriptionKey: description])
  }

  /// Never synchronously wait for the main queue while holding the state lock.
  private static func onMain(_ operation: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread { MainActor.assumeIsolated { operation() } }
    else { DispatchQueue.main.async(execute: operation) }
  }

  deinit { close() }
}
