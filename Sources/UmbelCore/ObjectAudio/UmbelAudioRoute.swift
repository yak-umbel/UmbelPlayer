import Foundation

/// Whether E-AC-3 with joint object coding goes to the system player, which
/// renders its objects, rather than being decoded here to its channels.
public enum UmbelObjectAudioMode: Sendable, Equatable {
  /// For such a track, in content of a known length, played through an
  /// output on the system's timeline (`SampleBufferAudioOutput`). While it
  /// plays, the engine serves the track on a port of this device's loopback
  /// address that the system picks.
  case automatic
  /// Never: the engine decodes every track, and serves nothing.
  case off
}

/// How the selected sound track is played.
public enum UmbelAudioRoute: Sendable, Equatable {
  /// No sound track plays.
  case none
  /// Decoded by the engine and played by its audio output.
  case engine
  /// Played by the system player; the engine shows the picture on its clock.
  case systemPlayer
  /// Decoded by the engine, after the system player could not play it.
  case engineAfterFallback(UmbelObjectAudioFallback)
}

/// Why the system player gave a sound track back to the engine.
public enum UmbelObjectAudioFallback: Error, Sendable, Equatable {
  /// The loopback server could not listen. A sandboxed Mac app needs the
  /// incoming network connections entitlement.
  case serverUnavailable(String)
  /// The system player failed the track.
  case playerFailed(String)
  /// Given everything it asked for, the system player did not play for five
  /// seconds.
  case notPlaying
}
