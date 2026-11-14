import Foundation

/// Tells a broken route from a slow one: the system player, meant to be
/// playing and given everything it asked for, still not playing after five
/// seconds. It starts within a third of a second of having data, so five
/// is some twenty times over. Waiting on reading is buffering, however
/// long, and starts the count again.
///
/// Any other standstill can be watched the same way, with a patience of its
/// own: `look(stuck:at:)`.
internal struct StallWatch: Sendable {
  static let patience = 5.0

  private let patience: Double
  private var since: Double?

  init(patience: Double = StallWatch.patience) {
    self.patience = patience
  }

  /// One look, at `now` seconds; true once stuck for `patience`.
  mutating func look(shouldPlay: Bool, isPlaying: Bool, waitingOnReading: Bool, at now: Double) -> Bool {
    look(stuck: shouldPlay && !isPlaying && !waitingOnReading, at: now)
  }

  /// One look, at `now` seconds; true once stuck for `patience` without a
  /// look in between finding it not.
  mutating func look(stuck: Bool, at now: Double) -> Bool {
    guard stuck else {
      since = nil
      return false
    }
    let start = since ?? now
    since = start
    return now - start >= patience
  }
}
