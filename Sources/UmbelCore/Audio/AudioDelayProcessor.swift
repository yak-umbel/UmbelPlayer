import CoreMedia
import Foundation

/// Moves PCM content against its original media clock. Outputs which play
/// frames continuously can use this; a system-timed output can shift PTS.
internal struct AudioDelayProcessor {
  private let seconds: Double
  private var isFirstFrame = true
  private var remainingSkip: Double

  init(seconds: Double) {
    self.seconds = seconds
    self.remainingSkip = max(0, -seconds)
  }

  mutating func process(_ frame: AudioFrame) -> [AudioFrame] {
    guard frame.frameCount > 0, frame.sampleRate > 0 else { return [] }
    if seconds == 0 { return [frame] }

    let first = isFirstFrame
    isFirstFrame = false
    if seconds > 0 {
      let silenceCount = first ? Int((seconds * frame.sampleRate).rounded()) : 0
      let shift = Double(Int((seconds * frame.sampleRate).rounded())) / frame.sampleRate
      let moved = AudioFrame(
        presentationTime: frame.presentationTime + CMTime(seconds: shift, preferredTimescale: 1_000_000),
        sampleRate: frame.sampleRate, channelCount: frame.channelCount,
        frameCount: frame.frameCount, samples: frame.samples)
      guard silenceCount > 0 else { return [moved] }
      let silence = AudioFrame(
        presentationTime: frame.presentationTime,
        sampleRate: frame.sampleRate, channelCount: frame.channelCount,
        frameCount: silenceCount,
        samples: [Float](repeating: 0, count: silenceCount * frame.channelCount))
      return [silence, moved]
    }

    let skipped = min(frame.frameCount, Int((remainingSkip * frame.sampleRate).rounded()))
    remainingSkip = max(0, remainingSkip - Double(skipped) / frame.sampleRate)
    guard skipped < frame.frameCount else { return [] }
    let kept = frame.frameCount - skipped
    let samples = (0..<frame.channelCount).flatMap { channel in
      Array(frame.samples[(channel * frame.frameCount + skipped)..<((channel + 1) * frame.frameCount)])
    }
    let shifted = frame.presentationTime + CMTime(
      seconds: seconds + Double(skipped) / frame.sampleRate, preferredTimescale: 1_000_000)
    return [AudioFrame(
      presentationTime: shifted, sampleRate: frame.sampleRate,
      channelCount: frame.channelCount, frameCount: kept, samples: samples)]
  }
}

/// The desired delay and the end of PCM already handed to a continuous output.
internal struct AudioTiming {
  private(set) var delay = CMTime.zero
  private var nextPCMTime: CMTime?
  private var nextSystemTime: CMTime?
  private var sourceEnd: CMTime?

  mutating func setDelay(_ value: CMTime) {
    delay = value
  }

  mutating func restart() {
    nextPCMTime = nil
    nextSystemTime = nil
    sourceEnd = nil
  }

  mutating func frames(for frame: AudioFrame, systemTimed: Bool) -> [AudioFrame] {
    if frame.presentationTime.isNumeric, frame.frameCount > 0 {
      // Continuity follows implausible timestamp jumps without filling them.
      // Follow the same new origin, keeping only the requested audio delay.
      if let sourceEnd,
         abs((frame.presentationTime - sourceEnd).seconds) > AudioContinuity.longestGap {
        restart()
      }
      sourceEnd = frame.presentationTime + frame.duration
    }
    if systemTimed { return timedFrames(for: frame) }
    guard frame.presentationTime.isNumeric, frame.frameCount > 0 else { return [frame] }
    // Already queued samples remain untouched. Fill or trim only the difference
    // between the next source frame's desired time and the output's end. Keeping
    // that end across settings changes also preserves an unfinished negative delay.
    let next = nextPCMTime ?? frame.presentationTime
    nextPCMTime = next
    var adjustment = AudioDelayProcessor(seconds: (frame.presentationTime + delay - next).seconds)
    let aligned = AudioFrame(
      presentationTime: next, sampleRate: frame.sampleRate,
      channelCount: frame.channelCount, frameCount: frame.frameCount, samples: frame.samples)
    let frames = adjustment.process(aligned)
    if let last = frames.last { nextPCMTime = last.presentationTime + last.duration }
    return frames
  }

  private mutating func timedFrames(for frame: AudioFrame) -> [AudioFrame] {
    let moved = frame.delayed(by: delay)
    guard moved.presentationTime.isNumeric, moved.frameCount > 0 else { return [moved] }
    let frames: [AudioFrame]
    if let next = nextSystemTime, moved.presentationTime < next {
      // The system already owns the previous samples. A reduced delay must
      // trim the overlap instead of queuing timestamps behind those samples.
      var adjustment = AudioDelayProcessor(seconds: (moved.presentationTime - next).seconds)
      frames = adjustment.process(AudioFrame(
        presentationTime: next, sampleRate: moved.sampleRate, channelCount: moved.channelCount,
        frameCount: moved.frameCount, samples: moved.samples))
    } else {
      frames = [moved]
    }
    if let last = frames.last { nextSystemTime = last.presentationTime + last.duration }
    return frames
  }

  /// A later setting cannot shorten sound that has already been handed on.
  var outputEnd: CMTime { max(nextPCMTime ?? .zero, nextSystemTime ?? .zero) }
}
