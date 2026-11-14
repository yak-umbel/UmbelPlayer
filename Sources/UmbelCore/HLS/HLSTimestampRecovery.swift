/// Confirms a shared timestamp change against adjacent playlist positions.
/// Observations require a packet position and DTS; PTS may be reordered.
internal struct HLSTimestampRecovery {
  enum Resolution: Equatable {
    case waiting
    case unchanged
    case corrected(segment: Int, by: Double)
  }

  /// Segment cuts can move the first audio packet by a few sample durations.
  static let agreementTolerance = 0.1

  private let tracks: [Int32: UmbelTrack.Kind]
  private var segment: HLSSegmentStream.Location?
  private var previous: [Int32: Double] = [:]
  private var first: [Int32: Double] = [:]
  private var previousSegment: Int?
  private var previousEnds: [Int32: Double] = [:]
  private var ends: [Int32: Double] = [:]
  private var shifts: [Int32: Double] = [:]
  private var playlistDelta = 0.0
  private var waiting = false

  init(tracks: [Int32: UmbelTrack.Kind]) {
    self.tracks = tracks.filter { $0.value == .audio || $0.value == .video }
  }

  mutating func observe(
    track: Int32, decode: Double, duration: Double = 0,
    segment next: HLSSegmentStream.Location?, positioned: Bool
  ) -> Resolution {
    guard let next else { return waiting ? .waiting : .unchanged }
    if segment == nil || next.index > segment!.index {
      let adjacent = segment.map { next.index == $0.index + 1 } ?? false
      playlistDelta = segment.map { next.start - $0.start } ?? 0
      previousSegment = segment?.index
      previous = first
      previousEnds = ends
      first.removeAll(keepingCapacity: true)
      ends.removeAll(keepingCapacity: true)
      shifts.removeAll(keepingCapacity: true)
      waiting = adjacent && tracks.values.contains(.audio) && tracks.values.contains(.video)
        && tracks.keys.allSatisfy { previous[$0] != nil }
      segment = next
    }
    guard tracks[track] != nil, decode.isFinite else {
      return waiting ? .waiting : .unchanged
    }
    let end = decode + (duration.isFinite && duration > 0 ? duration : 0)
    if next.index == previousSegment {
      // Other streams can still return the previous segment's tail while
      // the first stream waits for corroboration. Parser continuations
      // have inherited ownership and contribute their duration as well.
      previousEnds[track] = max(previousEnds[track] ?? end, end)
      return waiting ? .waiting : .unchanged
    }
    guard next.index == segment?.index else { return waiting ? .waiting : .unchanged }
    ends[track] = max(ends[track] ?? end, end)
    guard positioned, first[track] == nil else {
      return waiting ? .waiting : .unchanged
    }
    first[track] = decode
    guard waiting, let before = previous[track] else { return .unchanged }
    let shift = decode - before - playlistDelta
    shifts[track] = shift
    guard abs(shift) > HLSRunTimeline.continuityTolerance else {
      waiting = false
      return .unchanged
    }
    if let low = shifts.values.min(), let high = shifts.values.max(),
       high - low > Self.agreementTolerance {
      waiting = false
      return .unchanged
    }
    guard shifts.count == tracks.count else { return .waiting }
    // A late first DTS or a gap inside the previous segment can explain
    // the playlist residual without any reset at this boundary. Require
    // each actual tail-to-head gap to corroborate the same correction.
    guard tracks.keys.allSatisfy({ track in
      guard let head = first[track], let end = previousEnds[track],
            let shift = shifts[track] else { return false }
      let gap = head - end
      return abs(gap) > HLSRunTimeline.continuityTolerance
        && abs(gap - shift) <= Self.agreementTolerance
    }) else {
      waiting = false
      return .unchanged
    }
    // A common change preserves every track's relation to the video timeline.
    let video = tracks.keys.sorted().first { tracks[$0] == .video }!
    waiting = false
    return .corrected(segment: next.index, by: -shifts[video]!)
  }

  mutating func abandon() { waiting = false }
}
