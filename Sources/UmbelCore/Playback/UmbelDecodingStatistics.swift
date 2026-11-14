import Foundation

/// What a decoder has done with a track's packets since the track was
/// chosen: for a host's diagnostics. Reading it changes nothing.
///
/// Packets read with no frames coming out show here, rather than only as
/// buffering that does not end. A decoder made anew for the same track —
/// after the app was in the background, or for a stream encoded otherwise —
/// goes on counting; choosing another audio track starts again at zero.
public struct UmbelDecodingCounts: Sendable, Equatable {
  /// Frames the decoder handed out.
  public var decodedFrames: Int
  /// Packets it refused as damaged; they are skipped.
  public var rejectedPackets: Int
  /// Frames it failed when they were due, and skipped: damaged, or failed
  /// by a hardware decoder that lost its session. Decoding on several
  /// threads, a damaged packet can show here rather than as refused.
  public var damagedFrames: Int

  public init(decodedFrames: Int = 0, rejectedPackets: Int = 0, damagedFrames: Int = 0) {
    self.decodedFrames = decodedFrames
    self.rejectedPackets = rejectedPackets
    self.damagedFrames = damagedFrames
  }
}

/// The counts of the decoders a session has; see
/// `PlaybackSession.decodingStatistics`.
public struct UmbelDecodingStatistics: Sendable, Equatable {
  /// Nil when no picture is decoded here: none chosen, or the system
  /// decodes it.
  public var video: UmbelDecodingCounts?
  /// Nil when no sound is decoded here: none chosen, or the system player
  /// plays it.
  public var audio: UmbelDecodingCounts?

  public init(video: UmbelDecodingCounts? = nil, audio: UmbelDecodingCounts? = nil) {
    self.video = video
    self.audio = audio
  }
}
