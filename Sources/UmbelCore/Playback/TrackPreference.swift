import Foundation

/// Which track to pick when the host has not chosen one.
///
/// Kept apart from the playback session because it is a **pure rule** that
/// touches no session state, which is what makes it testable on its own: in a
/// container fixture the track marked default is often also the first one, so
/// testing only through a fixture would pass just as well with the rule
/// replaced by "take the first".
internal enum TrackPreference {
  /// The track the container marks as default; the earliest one otherwise.
  ///
  /// **When several are marked default, the earliest wins.** Containers allow
  /// that, so the rule has to be written down — otherwise the same file could
  /// pick a different track from one run to the next, and that kind of
  /// uncertainty is the hardest to chase.
  ///
  /// **Only tracks this engine can decode are candidates.** A file whose
  /// default sound no decoder here reads (AC-4, say) would otherwise not
  /// open at all; passing over it plays the next track, or the picture alone.
  ///
  /// No language preference lives here. That is a user setting, not knowledge
  /// the player should carry: the host reads `tracks` and names one through
  /// `selectAudioTrack(_:)`.
  internal static func preferred(
    of kind: UmbelTrack.Kind, in tracks: [UmbelTrack]
  ) -> UmbelTrack? {
    let candidates = tracks.filter { $0.kind == kind && $0.isDecodable }
    return candidates.first { $0.isDefault } ?? candidates.first
  }
}
