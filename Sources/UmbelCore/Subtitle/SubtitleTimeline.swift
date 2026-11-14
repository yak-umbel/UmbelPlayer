import CoreMedia
import Foundation

/// Decoded cues in start order, answering "what shows at this time".
///
/// A value type: whoever owns one — the decode session for an embedded track,
/// the session itself for an external file — already serialises access.
internal struct SubtitleTimeline: Sendable {
  enum Retention: Sendable {
    /// An embedded track: cues arrive as playback reaches them and are dropped
    /// once well past. Emptied on seek, since the stream restarts elsewhere.
    case window
    /// An external file: every cue loaded up front, kept for the whole session.
    case complete
  }

  /// How long past its end a cue is kept in a window. Enough that a query
  /// racing a prune never loses a cue still on screen.
  private static let pruneMargin = 1.0

  private let retention: Retention
  private var entries: [UmbelSubtitleCue] = []
  /// The longest explicit duration seen. It bounds how far back a lookup has
  /// to look, so a query stays short without missing a long cue.
  private var longestDuration = 0.0

  init(retention: Retention, cues: [UmbelSubtitleCue] = []) {
    self.retention = retention
    for cue in cues { insert(cue) }
  }

  var count: Int { entries.count }

  /// Keeps start order; cues with the same start keep arrival order.
  mutating func insert(_ cue: UmbelSubtitleCue) {
    let index = firstIndex(startingAfter: cue.start.seconds)
    entries.insert(cue, at: index)
    if let end = cue.end {
      longestDuration = max(longestDuration, end.seconds - cue.start.seconds)
    }
  }

  /// Ends every cue still showing at `time` that started before it. A cue
  /// that had already ended keeps its end; a cut never lengthens one.
  ///
  /// For bitmap formats, where each event replaces the whole picture.
  mutating func cut(at time: CMTime) {
    let seconds = time.seconds
    for index in entries.indices where entries[index].start.seconds < seconds {
      if let end = effectiveEnd(of: index), end <= seconds { continue }
      entries[index].end = time
      // An open-ended cue now has a length, and lookups must reach it.
      longestDuration = max(longestDuration, seconds - entries[index].start.seconds)
    }
  }

  /// Cues showing at `time`, in start order. Start is inside the interval,
  /// end is not; a cue without an end lasts until the next one starts.
  func cues(at time: CMTime) -> [UmbelSubtitleCue] {
    let now = time.seconds
    let upper = firstIndex(startingAfter: now)
    guard upper > 0 else { return [] }
    let latestStart = entries[upper - 1].start.seconds
    let earliestPossible = now - longestDuration

    var active: [UmbelSubtitleCue] = []
    var index = upper - 1
    while index >= 0 {
      let cue = entries[index]
      let start = cue.start.seconds
      // Open-ended cues only survive in the latest group; explicit ones can
      // reach no further back than the longest duration.
      if start < earliestPossible, start < latestStart { break }
      if isActive(at: index, now: now) { active.append(cue) }
      index -= 1
    }
    return active.reversed()
  }

  /// Drops cues that ended more than a moment before `time`. A complete
  /// timeline keeps everything: seeking back has to find them again.
  mutating func prune(before time: CMTime) {
    guard retention == .window else { return }
    let cutoff = time.seconds - Self.pruneMargin
    entries = entries.indices.compactMap { index in
      effectiveEnd(of: index).map { $0 <= cutoff } == true ? nil : entries[index]
    }
  }

  mutating func removeAll() {
    entries.removeAll()
    longestDuration = 0
  }

  private func isActive(at index: Int, now: Double) -> Bool {
    guard entries[index].start.seconds <= now else { return false }
    guard let end = effectiveEnd(of: index) else { return true }
    return now < end
  }

  /// The explicit end, else the start of the next cue that starts later.
  /// Nil when neither exists: the cue lasts until something replaces it.
  private func effectiveEnd(of index: Int) -> Double? {
    let cue = entries[index]
    if let end = cue.end { return end.seconds }
    let next = firstIndex(startingAfter: cue.start.seconds)
    return next < entries.count ? entries[next].start.seconds : nil
  }

  /// Binary search: the first entry whose start is later than `seconds`.
  private func firstIndex(startingAfter seconds: Double) -> Int {
    var low = 0
    var high = entries.count
    while low < high {
      let middle = (low + high) / 2
      if entries[middle].start.seconds <= seconds {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }
}
