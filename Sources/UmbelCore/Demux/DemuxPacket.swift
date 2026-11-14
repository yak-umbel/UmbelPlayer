import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// A compressed packet from the demuxer.
///
/// `data` is a copy of the buffer beneath. Compressed packets are one or two
/// orders of magnitude smaller than decoded frames, so the copy costs next
/// to nothing, while not copying would carry the type beneath across the
/// module boundary. Avoiding copies matters for decoded frames, not here.
public struct DemuxPacket: Sendable {
  public let trackID: UmbelTrack.ID
  public let data: Data
  /// Presentation time; `.invalid` when the container gives none (not
  /// `.zero`, which is a valid timestamp).
  public let presentationTime: CMTime
  /// Decode time; `.invalid` when the container gives none.
  public let decodeTime: CMTime
  /// The packet's duration; `.invalid` when the container gives none.
  public let duration: CMTime
  public let isKeyframe: Bool
  /// The parameters it decodes with, where they can change midway — in a
  /// playlist, each run's. Nil for a single file, whose decoders are made
  /// once. A decode session given another object makes a decoder for it.
  internal var decoderParameters: FFmpegCodecParameters?

  public init(
    trackID: UmbelTrack.ID,
    data: Data,
    presentationTime: CMTime,
    decodeTime: CMTime,
    duration: CMTime,
    isKeyframe: Bool
  ) {
    self.trackID = trackID
    self.data = data
    self.presentationTime = presentationTime
    self.decodeTime = decodeTime
    self.duration = duration
    self.isKeyframe = isKeyframe
  }
}
