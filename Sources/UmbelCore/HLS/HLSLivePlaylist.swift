import Foundation

/// A live playlist: the segments seen so far, fetched again as it grows.
///
/// Playing starts three target durations back from the newest segment and
/// its timeline starts there, at nought. Positions count from that segment
/// on, whatever the server's sequence numbers; a wait for one not listed
/// yet reloads the playlist, a target duration after a reload that brought
/// something, half of one after a reload that did not.
internal actor HLSLivePlaylist: HLSSegmentSource {
  struct Clock: Sendable {
    var now: @Sendable () -> Double
    var sleep: @Sendable (Double) async throws -> Void

    static let system = Clock(
      now: { ProcessInfo.processInfo.systemUptime },
      sleep: { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) })
  }

  /// Reloads failing one after another before playing gives up.
  static let reloadFailuresTolerated = 3
  /// How far back from the newest segment playing starts, in target
  /// durations.
  static let startDistance = 3.0

  typealias Segment = HLSMediaPlaylist.Segment

  private let reload: @Sendable () async throws -> HLSMediaPlaylist
  private let clock: Clock
  private var segments: [Segment] = []
  /// The playlist as last fetched: what the server still has.
  private var latest: HLSMediaPlaylist
  private var lastReload: Double
  private var lastReloadBroughtSome = true
  private var failuresInARow = 0
  private var failure: Error?
  private var lastRun = 0
  private var isCancelled = false
  private var waiting: Task<Void, Never>?

  init(
    first: HLSMediaPlaylist, reload: @escaping @Sendable () async throws -> HLSMediaPlaylist,
    clock: Clock = .system
  ) {
    self.reload = reload
    self.clock = clock
    self.latest = first
    self.lastReload = clock.now()
    var index = first.segments.count
    var ahead = 0.0
    while index > 0, ahead < Self.startDistance * Self.targetDuration(of: first) {
      index -= 1
      ahead += first.segments[index].duration
    }
    segments = Self.renumbered(Array(first.segments[index...]), from: 0, firstRun: 0)
    lastRun = segments.last?.run ?? 0
  }

  func segment(at index: Int) async throws -> Segment? {
    guard index >= 0 else { return nil }
    while true {
      if let failure { throw failure }
      if isCancelled { throw UmbelError.interrupted }
      if index < segments.count {
        // Held up, perhaps for long: the server may have dropped it since.
        if !latest.isEnded, clock.now() - lastReload >= Self.targetDuration(of: latest) {
          try? await refresh()
          if isCancelled { continue }
        }
        if segments[index].sequence < latest.mediaSequence { skipAhead(to: index) }
        return segments[index]
      }
      if latest.isEnded { return nil }
      let interval = Self.targetDuration(of: latest) / (lastReloadBroughtSome ? 1 : 2)
      let wait = lastReload + interval - clock.now()
      if wait > 0 { await pause(wait) }
      if isCancelled { continue }
      try? await refresh()
    }
  }

  func cancel() {
    isCancelled = true
    waiting?.cancel()
  }

  // ── Reloading ──────────────────────────────────────

  /// Fetches the playlist again and joins what is new. A failure is kept
  /// for good once there have been too many in a row.
  private func refresh() async throws {
    do {
      let fetched = try await reload()
      lastReload = clock.now()
      failuresInARow = 0
      let known = segments.count
      join(fetched)
      latest = fetched
      lastReloadBroughtSome = segments.count > known
    } catch {
      lastReload = clock.now()
      lastReloadBroughtSome = false
      failuresInARow += 1
      if failuresInARow >= Self.reloadFailuresTolerated {
        failure = UmbelError.sourceUnavailable(
          detail: "the live playlist cannot be had: \(UmbelError.detail(for: error))")
      }
      throw error
    }
  }

  /// Appends the segments after the last one known, by sequence number. One
  /// stays in the run before it only when the fetched list shows the two
  /// side by side with no discontinuity between; after a gap, whatever was
  /// missed may have been one.
  private func join(_ fetched: HLSMediaPlaylist) {
    guard var last = segments.last else { return }
    for segment in fetched.segments where segment.sequence > last.sequence {
      let position = segment.sequence - fetched.mediaSequence - 1
      let before = fetched.segments.indices.contains(position) ? fetched.segments[position] : nil
      let sameRun = before?.sequence == last.sequence && before?.run == segment.run
      if !sameRun { lastRun += 1 }
      let joined = Self.moved(segment, start: last.start + last.duration, run: lastRun)
      segments.append(joined)
      last = joined
    }
  }

  /// The segment at `index` is gone from the server: from there on, the
  /// oldest segments it still has, as a run of their own.
  private func skipAhead(to index: Int) {
    let start = segments[index].start
    let replacing = Self.renumbered(latest.segments, from: start, firstRun: lastRun + 1)
    segments.replaceSubrange(index..., with: replacing)
    lastRun = segments.last?.run ?? lastRun
  }

  private func pause(_ seconds: Double) async {
    let sleep = clock.sleep
    let task = Task { _ = try? await sleep(seconds) }
    waiting = task
    await task.value
    waiting = nil
  }

  // ── Placing segments ───────────────────────────────

  /// `segments` placed one after another from `start`, their runs kept
  /// apart as they were and numbered on from `firstRun`.
  private static func renumbered(_ segments: [Segment], from start: Double, firstRun: Int) -> [Segment] {
    guard let first = segments.first else { return [] }
    var clock = start
    return segments.map { segment in
      defer { clock += segment.duration }
      return moved(segment, start: clock, run: firstRun + segment.run - first.run)
    }
  }

  private static func moved(_ segment: Segment, start: Double, run: Int) -> Segment {
    Segment(
      url: segment.url, duration: segment.duration, start: start, run: run,
      byteRange: segment.byteRange, sequence: segment.sequence, key: segment.key, map: segment.map)
  }

  /// A playlist without one still needs something to wait by.
  private static func targetDuration(of playlist: HLSMediaPlaylist) -> Double {
    if playlist.targetDuration > 0 { return playlist.targetDuration }
    return max(playlist.segments.last?.duration ?? 1, 0.5)
  }
}
