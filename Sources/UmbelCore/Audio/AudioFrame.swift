import CoreMedia
import Foundation

/// Decoded PCM audio, normalised.
///
/// Always planar float32 — `AVAudioPCMBuffer`'s own layout, so nothing is
/// converted again on the way to the output.
public struct AudioFrame: Sendable {
  public let presentationTime: CMTime
  public let sampleRate: Double
  public let channelCount: Int
  /// Samples per channel.
  public let frameCount: Int
  /// Planar: all of channel 0's samples, then all of channel 1's, and so on.
  /// One flat array rather than `[[Float]]`, sparing each frame a second
  /// level of allocation.
  public let samples: [Float]

  public init(
    presentationTime: CMTime,
    sampleRate: Double,
    channelCount: Int,
    frameCount: Int,
    samples: [Float]
  ) {
    self.presentationTime = presentationTime
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCount = frameCount
    self.samples = samples
  }

  /// How long the frame lasts. `.invalid` for a bad sample rate; never inf.
  public var duration: CMTime {
    guard sampleRate > 0 else { return .invalid }
    return CMTime(seconds: Double(frameCount) / sampleRate, preferredTimescale: 1_000_000)
  }

  internal func delayed(by delay: CMTime) -> AudioFrame {
    guard delay != .zero else { return self }
    return AudioFrame(
      presentationTime: presentationTime + delay, sampleRate: sampleRate,
      channelCount: channelCount, frameCount: frameCount, samples: samples)
  }
}
