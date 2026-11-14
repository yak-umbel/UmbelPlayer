import CoreMedia

/// Joins frames too short for the system's sample buffer audio renderer.
///
/// Given sound in buffers of 40 samples — TrueHD's frames, 1/1200 s — the
/// renderer took them, said it was rendering, and played a blip, then
/// nothing. Frames shorter than `shortest` are held and joined, while they
/// carry on from one another in one format, until the join is long enough;
/// longer ones go as they are.
internal struct AudioFrameBatcher {
  /// In seconds. AAC's 1024 samples and DTS's 512 at 48 kHz both played.
  static let shortest = 0.02

  private var held: [AudioFrame] = []
  private var heldCount = 0

  /// After a seek: what is held belongs to before it.
  mutating func reset() {
    held.removeAll()
    heldCount = 0
  }

  /// What to hand on now: what was held, when `frame` does not carry on from
  /// it; then `frame` itself when long enough, or the join once it is.
  mutating func add(_ frame: AudioFrame) -> [AudioFrame] {
    var out: [AudioFrame] = []
    if let last = held.last, !Self.carriesOn(frame, from: last) {
      out.append(takeHeld())
    }
    let enough = Self.shortest * frame.sampleRate
    if held.isEmpty, Double(frame.frameCount) >= enough {
      return out + [frame]
    }
    held.append(frame)
    heldCount += frame.frameCount
    if Double(heldCount) >= enough { out.append(takeHeld()) }
    return out
  }

  /// Same format, and starting where `last` ends, within half a sample.
  private static func carriesOn(_ frame: AudioFrame, from last: AudioFrame) -> Bool {
    guard frame.sampleRate == last.sampleRate, frame.channelCount == last.channelCount else { return false }
    let end = last.presentationTime.seconds + Double(last.frameCount) / last.sampleRate
    return abs(frame.presentationTime.seconds - end) * frame.sampleRate < 0.5
  }

  /// The frames held, as one: each channel's samples one frame after another.
  private mutating func takeHeld() -> AudioFrame {
    defer { reset() }
    guard held.count > 1, let first = held.first else { return held[0] }
    let channels = first.channelCount
    var samples: [Float] = []
    samples.reserveCapacity(heldCount * channels)
    for channel in 0..<channels {
      for frame in held {
        let start = channel * frame.frameCount
        samples += frame.samples[start..<(start + frame.frameCount)]
      }
    }
    return AudioFrame(
      presentationTime: first.presentationTime, sampleRate: first.sampleRate,
      channelCount: channels, frameCount: heldCount, samples: samples)
  }
}
