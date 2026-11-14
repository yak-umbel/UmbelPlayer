import CoreMedia

/// Keeps the sound handed to the output in step with its timestamps.
///
/// An output times what it plays by the samples it has played: sound handed
/// over back to back plays back to back, whatever its timestamps say. Where
/// they leave a gap — an ad with no sound, a segment passed over — the gap
/// is handed over as silence; where they overlap, the part already played
/// is left out. Otherwise the sound after a gap plays early, ahead of the
/// picture, and stays ahead.
///
/// Silence put in and sound cut out are heard, though, where a small offset
/// is not: timestamps that wander around sound that is in fact continuous,
/// and offsets too small for a viewer to notice, are left alone.
///
/// And every frame handed on is stamped where it goes, on the sample: an
/// output that places sound by its timestamps — the system's renderer —
/// would otherwise play the rounding of a container that keeps milliseconds
/// as an overlap here and a gap there, a buzz at the frame rate.
internal struct AudioContinuity {
  /// How far sound can play from its picture before a viewer notices:
  /// 45 ms early, 125 ms late (ITU-R BT.1359). Within this a frame goes on
  /// where the last one ended, whatever its timestamp says. That covers the
  /// rounding of a container that keeps milliseconds, and the labels of a
  /// codec that packs a varying number of blocks to a packet, which wander
  /// some 23 ms around sound that is in fact continuous.
  static let unnoticed = Leeway(early: 0.045, late: 0.125)
  /// Further out than viewers accept — 90 ms early, 185 ms late — no
  /// wandering label explains: set right at once.
  static let accepted = Leeway(early: 0.09, late: 0.185)
  /// Between the two, an offset is set right once it has stayed on one side
  /// for this many frames in a row: a label that wanders is one packet's,
  /// gone by the next, where the offset of a splice or of drift stays.
  static let lastingFrames = 3
  /// More than this is a timestamp gone wrong, not missing sound: followed,
  /// not filled.
  static let longestGap = 600.0
  /// Silence goes out in pieces no longer than this, all sharing one buffer.
  static let silenceChunk = 0.5

  /// How far sound may play before its timestamp, or after it.
  struct Leeway {
    let early: Double
    let late: Double

    /// Whether sound due `gap` later than it will play, or `-gap` earlier,
    /// is within.
    func allows(_ gap: Double) -> Bool { gap <= early && -gap <= late }
  }

  /// Where the sound handed over so far ends, counted in samples: where the
  /// output will be when it has played them.
  private var end: Double?
  /// The offset past `unnoticed` the last frames kept, which way and for
  /// how many frames in a row; nil when the last frame was within it.
  private var held: (early: Bool, frames: Int)?
  /// The last frame was left out whole, played already: what of the next
  /// overlaps what was played is cut too, however little.
  private var leftOut = false
  private let diagnostics: UmbelPlaybackDiagnostics?

  init(diagnostics: UmbelPlaybackDiagnostics? = nil) { self.diagnostics = diagnostics }

  mutating func reset() {
    end = nil
    held = nil
    leftOut = false
    diagnostics?.record("audio_continuity_reset")
  }

  mutating func frames(for frame: AudioFrame) -> [AudioFrame] {
    guard frame.presentationTime.isValid, frame.sampleRate > 0, frame.frameCount > 0 else {
      return [frame]
    }
    let start = frame.presentationTime.seconds
    let length = Double(frame.frameCount) / frame.sampleRate
    guard let expected = end, abs(start - expected) <= Self.longestGap else {
      end = start + length
      held = nil
      leftOut = false
      return [Self.placed(frame, at: start)]
    }
    let gap = start - expected
    let overlapGoesOn = leftOut && Self.samples(-gap, frame.sampleRate) > 0
    leftOut = false
    if !overlapGoesOn, !setsRight(gap) {
      end = expected + length
      return [Self.placed(frame, at: expected)]
    }
    if gap > 0 {
      let after = expected + Self.samples(gap, frame.sampleRate) / frame.sampleRate
      end = after + length
      diagnostics?.record("audio_silence", values: [
        "expectedPTS": expected, "incomingPTS": start, "gap": gap,
        "silenceDuration": after - expected, "silenceSamples": Self.samples(gap, frame.sampleRate),
        "sampleRate": frame.sampleRate])
      return Self.silence(from: expected, lasting: gap, like: frame) + [Self.placed(frame, at: after)]
    }
    let skip = Int(Self.samples(-gap, frame.sampleRate))
    diagnostics?.record("audio_overlap", values: [
      "expectedPTS": expected, "incomingPTS": start, "gap": gap,
      "skippedSamples": Double(min(skip, frame.frameCount)), "sampleRate": frame.sampleRate])
    guard skip < frame.frameCount else {
      leftOut = true
      return []
    }
    let kept = Self.dropping(skip, from: frame, startingAt: expected)
    end = expected + Double(kept.frameCount) / frame.sampleRate
    return [kept]
  }

  /// Whether the sound is to be set right for a frame due `gap` later than
  /// it will play (earlier, if negative): at once past `accepted`, once the
  /// offset has lasted past `unnoticed`.
  private mutating func setsRight(_ gap: Double) -> Bool {
    guard !Self.unnoticed.allows(gap) else {
      held = nil
      return false
    }
    let early = gap > 0
    let frames = held?.early == early ? (held?.frames ?? 0) + 1 : 1
    guard Self.accepted.allows(gap), frames < Self.lastingFrames else {
      held = nil
      return true
    }
    held = (early, frames)
    return false
  }

  private static func samples(_ seconds: Double, _ rate: Double) -> Double {
    (seconds * rate).rounded()
  }

  /// A time on the frame's own sample grid: frames placed back to back meet
  /// to the sample. Rounded to the nearest sample, where converting seconds
  /// cuts down to the one before: a sum of frame lengths that falls a hair
  /// short would stamp the next frame a sample early.
  private static func time(_ seconds: Double, _ rate: Double) -> CMTime {
    let scale = rate.rounded()
    return CMTime(value: CMTimeValue((seconds * scale).rounded()), timescale: CMTimeScale(scale))
  }

  private static func placed(_ frame: AudioFrame, at seconds: Double) -> AudioFrame {
    AudioFrame(
      presentationTime: time(seconds, frame.sampleRate), sampleRate: frame.sampleRate,
      channelCount: frame.channelCount, frameCount: frame.frameCount, samples: frame.samples)
  }

  private static func silence(from start: Double, lasting seconds: Double, like frame: AudioFrame) -> [AudioFrame] {
    let rate = frame.sampleRate
    let channels = frame.channelCount
    var remaining = Int(samples(seconds, rate))
    let chunk = max(1, Int(samples(silenceChunk, rate)))
    let full = [Float](repeating: 0, count: chunk * channels)
    var pieces: [AudioFrame] = []
    var at = start
    while remaining > 0 {
      let count = min(chunk, remaining)
      pieces.append(AudioFrame(
        presentationTime: time(at, rate),
        sampleRate: rate, channelCount: channels, frameCount: count,
        samples: count == chunk ? full : [Float](repeating: 0, count: count * channels)))
      at += Double(count) / rate
      remaining -= count
    }
    return pieces
  }

  /// `frame` less its first `skip` samples in every channel.
  private static func dropping(_ skip: Int, from frame: AudioFrame, startingAt start: Double) -> AudioFrame {
    let count = frame.frameCount - skip
    var samples: [Float] = []
    samples.reserveCapacity(count * frame.channelCount)
    for channel in 0..<frame.channelCount {
      let first = channel * frame.frameCount + skip
      samples += frame.samples[first..<(first + count)]
    }
    return AudioFrame(
      presentationTime: time(start, frame.sampleRate),
      sampleRate: frame.sampleRate, channelCount: frame.channelCount, frameCount: count,
      samples: samples)
  }
}
