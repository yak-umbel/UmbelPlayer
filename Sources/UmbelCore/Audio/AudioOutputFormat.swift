import Foundation

/// The format a track's sound is played in: its own rate and channel count,
/// or 48 kHz stereo where it does not say.
///
/// The output is prepared in it and decoders convert into it, so the two
/// agree even when the content's own format changes midway — an ad spliced
/// in at another rate would otherwise play fast and high.
internal struct AudioOutputFormat: Equatable, Sendable {
  let sampleRate: Double
  let channelCount: Int

  static func `for`(_ track: UmbelTrack) -> AudioOutputFormat {
    AudioOutputFormat(
      sampleRate: Double(track.audio?.sampleRate ?? 48_000),
      channelCount: track.audio?.channelCount ?? 2)
  }
}
