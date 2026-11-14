import AVFoundation
import CoreMedia
import Foundation
import UmbelFFmpegSupport
import UmbelObjCSupport

/// Output through the system's audio engine.
///
/// Buffers are scheduled rather than rendered in a callback: a render
/// callback runs on a real-time thread, where locking or allocating is not
/// allowed, and Swift's reference counting, exclusivity checks and copy on
/// write may all allocate there — heard as the odd crackle, and never in a
/// test. Scheduling keeps our code off the real-time thread entirely, at the
/// cost of a little latency from its granularity.
///
/// Time comes from `playerTime(forNodeTime:)`, which is exact to the
/// sample: scheduling costs the clock no precision.
public actor EngineAudioOutput: AudioOutput, PlaybackDiagnosticsReceiving {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  /// Between the player and the mixer: speed without a change of pitch. At
  /// the normal rate it is bypassed, and the sound is as it was without it.
  /// The player's own time still counts media: the unit pulls from it at the
  /// rate, so its samples played are the media played.
  private let timePitch: AVAudioUnitTimePitch = {
    let unit = AVAudioUnitTimePitch()
    unit.bypass = true
    return unit
  }()
  private var format: AVAudioFormat?
  private var isPrepared = false
  private var firstFrameTime: CMTime?
  private var generation = 0
  private var diagnostics: UmbelPlaybackDiagnostics?

  internal func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) {
    self.diagnostics = diagnostics
  }

  /// Bounded slots for buffers in flight. This is where the backpressure is:
  /// only a full set waits.
  ///
  /// **Scheduling each buffer only after the last has played will not do**:
  /// with one buffer in flight at a time there are gaps between them, and
  /// the sound breaks up.
  private let slots = BufferSlots(capacity: 8)

  /// The engine stops the audio hardware itself once it has idled a while,
  /// and starts it again when needed — Apple's power saving for an engine
  /// that is not paused; see `pause()`.
  public init() {
    engine.isAutoShutdownEnabled = true
  }

  /// Whether the engine, not only the player, is running.
  internal var isEngineRunning: Bool { engine.isRunning }

  /// Planar float in the decoder's channel order.
  ///
  /// Above two channels AVAudioFormat has to be told which speaker each
  /// channel is for, or it refuses the format — and a film in 5.1 plays
  /// without sound. The layout is given as a channel bitmap: FFmpeg's masks
  /// and CoreAudio's bitmaps share the WAVE bit order, and the channels
  /// arrive in ascending bit order in both. The system mixer then folds the
  /// channels down to whatever the device has, or keeps them on a device that
  /// has the speakers.
  static func makeFormat(sampleRate: Double, channelCount: Int) -> AVAudioFormat? {
    guard channelCount > 2 else {
      return AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))
    }
    // CoreAudio's bitmap stops at the top back pair, bit 17.
    guard let mask = FFmpegResampler.defaultChannelMask(channelCount: channelCount),
          mask < 1 << 18 else { return nil }
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
    layout.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(mask))
    return AVAudioFormat(
      standardFormatWithSampleRate: sampleRate, channelLayout: AVAudioChannelLayout(layout: &layout))
  }

  public func prepare(sampleRate: Double, channelCount: Int) async throws {
    guard let format = Self.makeFormat(sampleRate: sampleRate, channelCount: channelCount) else {
      throw UmbelError.audioOutputUnavailable(
        reason: "unsupported output format: \(sampleRate) Hz, \(channelCount) channels")
    }

    // **The format is settled before any suspension point.**
    //
    // `slots.reset()` below awaits, letting go of enqueues waiting for a
    // slot, and each wakes to build its buffer from `self.format`. Were the
    // format still the old one, it would hand an old-format buffer to a
    // player just reconnected — an Objective-C exception, and the process
    // ends.
    let previous = self.format
    self.format = format

    if !isPrepared {
      engine.attach(player)
      engine.attach(timePitch)
      try connectChain(format)
      isPrepared = true
    } else if previous != format {
      // The contract is that calling again reconfigures. Updating the format
      // without reconnecting leaves the node working in the old one — met on
      // switching to an audio track with another channel count. The node is
      // stopped before reconnecting, or the connection would change under
      // buffers still queued.
      player.stop()
      // The time-pitch unit takes a new format only with the engine stopped
      // (error -10868 otherwise). Only a track switch to another format
      // comes here, and it stops the player anyway.
      let wasRunning = engine.isRunning
      if wasRunning { engine.stop() }
      try connectChain(format)
      if wasRunning { try? engine.start() }
      firstFrameTime = nil
      generation += 1
      await slots.reset()
    }
  }

  private func connectChain(_ format: AVAudioFormat) throws {
    try Self.guarded {
      engine.connect(player, to: timePitch, format: format)
      engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }
  }

  public func setRate(_ rate: Double) {
    timePitch.rate = Float(rate)
    timePitch.bypass = rate == 1
  }

  public func setVolume(_ volume: Float, muted: Bool) {
    engine.mainMixerNode.outputVolume = muted ? 0 : volume
  }

  /// For tests: the mixer's output level.
  internal var mixerVolume: Float { engine.mainMixerNode.outputVolume }

  /// The time-pitch unit's rate, whether it is bypassed, and whether the
  /// player feeds it. For tests.
  internal var timePitchState: (rate: Float, bypassed: Bool, isInTheChain: Bool) {
    let next = engine.outputConnectionPoints(for: player, outputBus: 0).first?.node
    return (timePitch.rate, timePitch.bypass, next === timePitch)
  }

  /// The channel count the player is connected with. Tests use it to check
  /// that reconfiguring happened.
  internal var connectedChannelCount: Int {
    Int(player.outputFormat(forBus: 0).channelCount)
  }

  public func enqueue(_ frame: AudioFrame) async throws {
    guard frame.frameCount > 0 else { return }
    let requestedGeneration = generation

    // **Take a slot first, then build the buffer in the format of that
    // moment.**
    //
    // The other way round leaves a fatal window: taking a slot may wait,
    // and meanwhile an audio track switch may change the format and
    // reconnect the player; waking to hand over a buffer built in the old
    // format, `AVAudioPlayerNode` raises an Objective-C exception and the
    // process ends (required condition is false: _outputFormat.channelCount
    // == buffer.format.channelCount). The test double does not check
    // formats, so only acceptance on a real device ran into it.
    //
    // From taking the slot to scheduling there is no suspension point, so
    // the format cannot change in between.
    await slots.acquire()
    guard requestedGeneration == generation else { return }

    guard let format else {
      await slots.release()
      throw UmbelError.audioOutputUnavailable(reason: "not prepared")
    }
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frame.frameCount)
    ) else {
      await slots.release()
      throw UmbelError.audioOutputUnavailable(reason: "cannot allocate a playback buffer")
    }
    buffer.frameLength = AVAudioFrameCount(frame.frameCount)

    guard let channels = buffer.floatChannelData else {
      await slots.release()
      throw UmbelError.audioOutputUnavailable(reason: "the playback buffer is not floating point")
    }

    if firstFrameTime == nil, frame.presentationTime.isValid {
      firstFrameTime = frame.presentationTime
    }

    // The input is planar: channel c's samples are at [c * frameCount,
    // (c+1) * frameCount). With a channel count that does not match, only
    // the first channels are filled: an old track's mono landing in a stereo
    // buffer sounds in one channel for twenty-odd milliseconds, unheard.
    let channelCount = min(frame.channelCount, Int(format.channelCount))
    frame.samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      for channel in 0..<channelCount {
        channels[channel].update(
          from: base + channel * frame.frameCount, count: frame.frameCount)
      }
    }

    // The completion handler is a sending parameter and **must not capture
    // self**: the actor's mutable state would count as a data race risk, and
    // toolchains differ in how strictly. Only the slots are captured, an
    // actor safe to reach from any thread — which the handler comes back on.
    let slots = self.slots
    do {
      try Self.guarded { player.scheduleBuffer(buffer) { Task { await slots.release() } } }
    } catch {
      // Not scheduled, so its completion will never hand the slot back.
      await slots.release()
      throw error
    }
  }

  public func flush() async {
    // Only the player stops: that drops its scheduled buffers and puts its
    // time back to zero, which is what a seek wants. **The engine is left
    // alone**: started again after engine.stop(), it takes about half a
    // second.
    generation += 1
    player.stop()
    firstFrameTime = nil
    await slots.reset()
  }

  public func start() async throws {
    diagnostics?.record("engine_start", values: ["generation": Double(generation)],
                        labels: ["wasRunning": String(engine.isRunning)])
    guard isPrepared else {
      throw UmbelError.audioOutputUnavailable(reason: "not prepared")
    }
    do {
      try engine.start()
    } catch {
      throw UmbelError.audioOutputUnavailable(reason: error.localizedDescription)
    }
    // An engine that started can still have no working device beneath it;
    // the player then raises "did not see an IO cycle".
    try Self.guarded { player.play() }
  }

  /// Runs an AVFAudio call that may raise an Objective-C exception, as an
  /// error instead.
  ///
  /// AVFAudio reports some runtime faults that way — an output device that
  /// stopped delivering, a format a node will not take — and Swift cannot
  /// catch them: the host app would simply crash. As an error the session
  /// reports it, with its reason, and the app carries on.
  internal static func guarded(_ action: () -> Void) throws {
    var failure: NSError?
    guard UmbelCatchingObjCException(action, &failure) else {
      throw UmbelError.audioOutputUnavailable(
        reason: failure?.localizedDescription ?? "the audio framework raised an exception")
    }
  }

  /// Pauses the player; the engine runs on. Pausing the engine stops the
  /// audio hardware, and starting it again took 160 to 250 ms here: sound
  /// came back that much after every seek, since a seek pauses too. With
  /// auto shutdown on, the engine stops the hardware itself when a pause
  /// lasts — the power saving Apple advises pausing the engine for.
  public func pause() async {
    player.pause()
    diagnostics?.record("engine_pause", values: ["generation": Double(generation)],
                        labels: ["engineRunning": String(engine.isRunning)])
  }

  public func stop() async {
    generation += 1
    player.stop()
    engine.stop()
    firstFrameTime = nil
    await slots.reset()
  }

  public var currentAnchor: RenderAnchor? {
    // No anchor before the first frame is scheduled: there is no media time
    // yet. Falling back to 0 would drag the clock to the start after a seek,
    // since nothing is scheduled while the discard window lasts — exactly
    // this window.
    guard let firstFrameTime else {
      diagnostics?.record("audio_anchor_unavailable", labels: ["reason": "noFirstFrame"])
      return nil
    }
    // A render time with nothing valid in it — an engine started over a
    // device that never ran — makes the player raise rather than answer.
    guard let nodeTime = player.lastRenderTime,
          nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
          let playerTime = player.playerTime(forNodeTime: nodeTime),
          playerTime.sampleRate > 0 else {
      diagnostics?.record("audio_anchor_unavailable", values: ["firstFramePTS": firstFrameTime.seconds],
                          labels: ["reason": "noPlayerTime"])
      return nil
    }
    let played = Double(playerTime.sampleTime) / playerTime.sampleRate
    let anchor = RenderAnchor(
      mediaTime: CMTime(
        seconds: firstFrameTime.seconds + played, preferredTimescale: 1_000_000),
      hostTime: CMClockGetTime(CMClockGetHostTimeClock())
    )
    diagnostics?.record("audio_anchor", values: [
      "firstFramePTS": firstFrameTime.seconds, "playerSampleTime": Double(playerTime.sampleTime),
      "playerSampleRate": playerTime.sampleRate, "nodeSampleTime": Double(nodeTime.sampleTime),
      "nodeHost": nodeTime.isHostTimeValid ? AVAudioTime.seconds(forHostTime: nodeTime.hostTime) : .nan,
      "renderAge": nodeTime.isHostTimeValid
        ? anchor.hostTime.seconds - AVAudioTime.seconds(forHostTime: nodeTime.hostTime) : .nan,
      "anchorMedia": anchor.mediaTime.seconds, "anchorHost": anchor.hostTime.seconds,
      "generation": Double(generation)], labels: [
        "nodeHostValid": String(nodeTime.isHostTimeValid),
        "nodeSampleValid": String(nodeTime.isSampleTimeValid), "playerPlaying": String(player.isPlaying),
        "engineRunning": String(engine.isRunning)])
    return anchor
  }
}


/// Bounded slots.
///
/// An actor rather than a class with a lock, for two reasons: a lock cannot
/// be held across a suspension point (Swift 6 forbids taking one in an async
/// context), and the completion handler, a sending parameter, may safely
/// capture an actor held in a `let`, while capturing the output's `self`
/// counts as a data race risk — judged more or less strictly by different
/// toolchains, more strictly on CI's.
private actor BufferSlots {
  private let capacity: Int
  private var used = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(capacity: Int) {
    self.capacity = max(1, capacity)
  }

  /// Takes a slot, waiting for one if all are taken.
  func acquire() async {
    if used < capacity {
      used += 1
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
    // Woken means release handed its slot straight over; used stays as is.
  }

  /// Gives a slot back — straight to a waiting caller, if there is one, so
  /// the count does not bounce.
  func release() {
    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume()
      return
    }
    used = max(0, used - 1)
  }

  /// Empties. Every waiting caller is let go, or stopping playback would
  /// leave them waiting for good.
  func reset() {
    used = 0
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
