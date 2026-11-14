/// Where a playback session stands.
///
/// Only the engine moves it on; interfaces and hosts only read it. The usual
/// course is `idle → opening → buffering → playing ⇄ paused → ended`, and any
/// phase may go to `failed`.
public enum UmbelPlaybackPhase: String, Sendable, CaseIterable {
  /// Nothing loaded yet.
  case idle
  /// Opening the source, probing the container and its tracks.
  case opening
  /// Open, gathering enough to play.
  case buffering
  /// The playhead is moving.
  case playing
  /// Paused; the playhead stays where it is.
  case paused
  /// Played to the end of the content.
  case ended
  /// Failed beyond recovery.
  case failed
}

public extension UmbelPlaybackPhase {
  /// Terminal: it moves on by itself no more, and only an outside action
  /// leaves it.
  var isTerminal: Bool {
    self == .ended || self == .failed
  }

  /// Whether the playhead is moving.
  var isAdvancing: Bool {
    self == .playing
  }

  /// Whether content is open (its tracks are known).
  var hasOpenedContent: Bool {
    switch self {
    case .idle, .opening, .failed:
      return false
    case .buffering, .playing, .paused, .ended:
      return true
    }
  }
}
