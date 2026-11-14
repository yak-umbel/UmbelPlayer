import CoreMedia
import Foundation

/// An output that plays in virtual time, to check the clock without audio
/// hardware.
///
/// `rateFactor` stands for a real device's deviation from its nominal rate:
/// hardware is never exactly 48000 Hz, and the audio clock slowly parts from
/// the host clock. Drift tests have to bring that imperfection in; driven by
/// one virtual time, the two would never drift and the test would prove only
/// itself.
public actor VirtualAudioOutput: AudioOutput {
  private let hostTime: HostTimeSource
  private let rateFactor: Double
  private let maxPendingSeconds: Double

  private var isRunning = false
  private var rate = 1.0
  private var availableSeconds: Double = 0    // queued, not yet played
  private var consumedSeconds: Double = 0     // played
  private var baseMediaSeconds: Double?       // where the first frame starts
  private var anchor: RenderAnchor?
  private var waitingProducers: [CheckedContinuation<Void, Never>] = []

  public init(
    hostTime: HostTimeSource,
    rateFactor: Double = 1.0,
    maxPendingSeconds: Double = 1.0
  ) {
    self.hostTime = hostTime
    self.rateFactor = rateFactor
    self.maxPendingSeconds = maxPendingSeconds
  }

  public var currentAnchor: RenderAnchor? { anchor }

  /// How much is queued but not yet played. Tests use it to check the
  /// backpressure holds.
  public var pendingSeconds: Double { availableSeconds }

  /// Frames handed over in another format than prepared. A real output
  /// builds its buffers in the prepared format, so such a frame would play
  /// at the wrong speed; the double counts them rather than play along.
  public private(set) var mismatchedFrameCount = 0
  private var prepared: (sampleRate: Double, channelCount: Int)?

  public func prepare(sampleRate: Double, channelCount: Int) async throws {
    prepared = (sampleRate, channelCount)
  }

  public func enqueue(_ frame: AudioFrame) async throws {
    if let prepared,
       prepared.sampleRate != frame.sampleRate || prepared.channelCount != frame.channelCount {
      mismatchedFrameCount += 1
    }
    // Backpressure: full, wait for playing, **whether playing or not**. The
    // protocol says full means wait; not waiting while paused would let
    // feeding decode the whole file into memory. Filling up before playing
    // is unaffected: the limit is an allowance, checked before adding.
    while availableSeconds >= maxPendingSeconds {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        waitingProducers.append(continuation)
      }
    }
    if baseMediaSeconds == nil, frame.presentationTime.isValid {
      baseMediaSeconds = frame.presentationTime.seconds
    }
    availableSeconds += Double(frame.frameCount) / frame.sampleRate
  }

  public func start() async throws {
    isRunning = true
  }

  public func pause() async {
    isRunning = false
  }

  public func setRate(_ rate: Double) {
    self.rate = rate
  }

  /// The level last set, for tests to read.
  public private(set) var volume: Float = 1
  public private(set) var isMuted = false

  public func setVolume(_ volume: Float, muted: Bool) {
    self.volume = volume
    isMuted = muted
  }

  /// No real device, so the same as `stop()`.
  public func flush() async {
    await stop()
  }

  public func stop() async {
    isRunning = false
    availableSeconds = 0
    consumedSeconds = 0
    baseMediaSeconds = nil
    anchor = nil
    releaseProducers()
  }

  /// Plays on in virtual time. Tests drive it; the real thing, hardware.
  public func advance(bySeconds hostDelta: Double) async {
    guard isRunning, hostDelta > 0 else { return }
    // Without more audio it cannot move on from nothing — that would put the
    // clock ahead of the content.
    let wanted = hostDelta * rateFactor * rate
    let consumed = min(wanted, availableSeconds)
    guard consumed > 0 else { return }
    availableSeconds -= consumed
    consumedSeconds += consumed
    anchor = RenderAnchor(
      mediaTime: CMTime(
        seconds: (baseMediaSeconds ?? 0) + consumedSeconds,
        preferredTimescale: 1_000_000
      ),
      hostTime: hostTime.now
    )
    releaseProducers()
  }

  private func releaseProducers() {
    let waiting = waitingProducers
    waitingProducers.removeAll()
    for producer in waiting { producer.resume() }
  }
}
