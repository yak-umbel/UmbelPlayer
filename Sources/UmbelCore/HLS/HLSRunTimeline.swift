import CoreMedia

/// Moves each run's own timestamps onto the playlist's timeline.
///
/// An initial offset a run, set by its first packet: the run's place in the
/// playlist less that packet's own time. A spliced ad starts its timestamps
/// over and the film after it runs on from before it; mapped this way both
/// land where the playlist puts them, and a seek to any point finds what the
/// progress bar shows there.
///
/// A run whose first timestamp follows on from the last run's end — within
/// `continuityTolerance` — keeps that run's offset: many playlists tag runs
/// whose timestamps never break, and the playlist's rounded durations would
/// otherwise nudge the timeline a few hundredths at every tag.
internal struct HLSRunTimeline {
  static let continuityTolerance = 1.0

  private var offset: Double?
  private var runStart = 0.0
  private var followsOn = false
  private var needsAnchor = true
  /// This run's packets' latest own end: time plus duration.
  private var lastEnd: Double?
  /// The run before's, which a new run's first packet is held against.
  private var previousEnd: Double?
  private var segmentOffsets: [(segment: Int, offset: Double)] = []
  private var latestSegment: Int?
  private let diagnostics: UmbelPlaybackDiagnostics?

  init(diagnostics: UmbelPlaybackDiagnostics? = nil) { self.diagnostics = diagnostics }

  /// `continuing`: the run follows the one before in order, rather than
  /// after a seek or a segment passed over.
  mutating func beginRun(startingAt start: Double, continuing: Bool) {
    runStart = start
    followsOn = continuing
    needsAnchor = true
    previousEnd = continuing ? lastEnd : nil
    lastEnd = nil
    segmentOffsets.removeAll(keepingCapacity: true)
    latestSegment = nil
    diagnostics?.record("hls_run_begin", values: [
      "runStart": start, "previousEnd": previousEnd ?? .nan, "previousOffset": offset ?? .nan],
      labels: ["continuing": String(continuing)])
  }

  mutating func place(
    presentation: CMTime, decode: CMTime, duration: CMTime, segment: Int? = nil
  ) -> (presentation: CMTime, decode: CMTime) {
    let own = presentation.isValid ? presentation : decode
    guard own.isValid else { return (presentation, decode) }
    if needsAnchor {
      needsAnchor = false
      let runsOn = followsOn && offset != nil
        && previousEnd.map { abs(own.seconds - $0) <= Self.continuityTolerance } == true
      if !runsOn { offset = runStart - own.seconds }
      diagnostics?.record("hls_anchor", values: [
        "runStart": runStart, "sourcePTS": presentation.seconds, "sourceDTS": decode.seconds,
        "previousEnd": previousEnd ?? .nan, "offset": offset ?? 0],
        labels: ["decision": runsOn ? "preserved" : "reanchored"])
    }
    let shift = segment.flatMap { index in
      segmentOffsets.last { $0.segment <= index }?.offset
    } ?? offset ?? 0
    let end = own.seconds + (duration.isValid ? duration.seconds : 0)
    if segment == nil || segment! >= latestSegment ?? Int.min {
      latestSegment = segment
      lastEnd = max(lastEnd ?? end, end)
    }
    return (moved(presentation, by: shift), moved(decode, by: shift))
  }

  /// Earlier packets can still emerge after a boundary has been confirmed.
  mutating func correct(by seconds: Double, startingAt segment: Int) {
    guard let old = offset, seconds.isFinite else { return }
    if segmentOffsets.isEmpty { segmentOffsets.append((Int.min, old)) }
    offset = old + seconds
    segmentOffsets.append((segment, old + seconds))
    latestSegment = segment
    lastEnd = nil
    diagnostics?.record("hls_timestamp_recovery", values: [
      "segment": Double(segment), "correction": seconds, "offset": old + seconds])
  }

  private func moved(_ time: CMTime, by seconds: Double) -> CMTime {
    guard time.isValid else { return time }
    return CMTime(seconds: time.seconds + seconds, preferredTimescale: 1_000_000)
  }
}
