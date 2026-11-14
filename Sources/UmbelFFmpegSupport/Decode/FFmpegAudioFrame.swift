import Foundation

/// Decoded, normalised PCM, keeping FFmpeg's shape of time.
///
/// Timestamps are integer ticks in the stream's time base, which comes with
/// them for the layer above to convert. This module does not know the
/// domain types exist: the dependency runs one way.
public struct FFmpegAudioFrame: Sendable, Equatable {
  /// Planar float32: all of channel 0's samples, then channel 1's, and so on.
  public let samples: [Float]
  /// Samples per channel.
  public let frameCount: Int
  public let channelCount: Int
  public let sampleRate: Int32
  public let pts: Int64
  public let timeBaseNum: Int32
  public let timeBaseDen: Int32

  public init(
    samples: [Float],
    frameCount: Int,
    channelCount: Int,
    sampleRate: Int32,
    pts: Int64,
    timeBaseNum: Int32,
    timeBaseDen: Int32
  ) {
    self.samples = samples
    self.frameCount = frameCount
    self.channelCount = channelCount
    self.sampleRate = sampleRate
    self.pts = pts
    self.timeBaseNum = timeBaseNum
    self.timeBaseDen = timeBaseDen
  }
}
