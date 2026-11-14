import CoreMedia
import Foundation

/// Already-consumed compressed media. Owned by PacketCache's actor. Removing
/// a prefix preserves the remaining stream order; losing a packet in the
/// middle discards that track's older history instead of leaving a hole.
internal struct BackwardPacketHistory {
  typealias Entry = SeekEntry.Entry
  private let maximumBytes: Int
  private let videoTracks: Set<UmbelTrack.ID>
  private var tracks: [UmbelTrack.ID: Track] = [:]
  private(set) var bytes = 0

  init(maximumBytes: Int, videoTracks: Set<UmbelTrack.ID>) {
    self.maximumBytes = max(0, maximumBytes)
    self.videoTracks = videoTracks
  }

  func entries(for track: UmbelTrack.ID) -> [Entry] { tracks[track]?.snapshot ?? [] }

  /// What a rewind to `target` would replay: per track, its history and its
  /// queue joined, and where in them replay starts.
  enum RewindPlan {
    case replay([UmbelTrack.ID: (entries: [Entry], start: Int)])
    /// Why the target cannot be replayed whole from history.
    case miss(String)
  }

  /// Plans a rewind of `video` and `audio` to `target`: each starts where
  /// reading after a seek would (`SeekEntry`), in its history and `queues`
  /// joined, which must run on without a gap from there; sound must reach
  /// back to its warm-up as well. A plan needing no history at all misses:
  /// the queues alone are a forward seek's to keep. `dropped` says whether
  /// a track lost packets past the target.
  func planRewind(
    to target: Double, video: UmbelTrack.ID?, audio: UmbelTrack.ID?,
    queues: [UmbelTrack.ID: [Entry]], dropped: (UmbelTrack.ID) -> Bool
  ) -> RewindPlan {
    var plan: [UmbelTrack.ID: (entries: [Entry], start: Int)] = [:]
    var usesHistory = false
    for (track, start) in [(video, SeekEntry.pictureStart), (audio, SeekEntry.soundStart)] {
      guard let track else { continue }
      let past = entries(for: track)
      let combined = past + (queues[track] ?? [])
      guard !dropped(track), let index = start(combined, target), Self.isContinuous(combined[index...]) else {
        return .miss(track == video ? "videoHistoryIncomplete" : "audioHistoryIncomplete")
      }
      if track == audio,
         (SeekEntry.start(of: combined[index].packet) ?? .infinity)
          > max(0, target - PrerollFilter.audioWarmUp) + 0.000001 {
        return .miss("audioWarmupUnavailable")
      }
      usesHistory = usesHistory || index < past.count
      plan[track] = (combined, index)
    }
    return usesHistory ? .replay(plan) : .miss("historyUnavailable")
  }

  mutating func append(_ entry: Entry) {
    guard maximumBytes > 0 else { return }
    let packet = entry.packet
    let track = packet.trackID
    let charge = packet.data.count
    guard charge > 0, charge <= maximumBytes, Self.time(packet) != nil else {
      remove(track)
      return
    }
    if let previous = tracks[track]?.last?.packet,
       !Self.follows(packet, after: previous) {
      remove(track)
    }
    if videoTracks.contains(track), tracks[track]?.isEmpty != false, !packet.isKeyframe { return }
    // Make room before charging; addition cannot overflow even for Int.max budgets.
    while bytes > maximumBytes - charge { evictOldest() }
    // Eviction may have removed this track's decoding entry point.
    if videoTracks.contains(track), tracks[track]?.isEmpty != false, !packet.isKeyframe { return }
    tracks[track, default: Track()].append(entry)
    bytes += charge
  }

  mutating func remove(_ track: UmbelTrack.ID) {
    bytes -= tracks.removeValue(forKey: track)?.bytes ?? 0
  }

  mutating func removeAll() {
    tracks.removeAll()
    bytes = 0
  }

  private mutating func evictOldest() {
    guard let track = tracks.keys.min(by: {
      let lhs = tracks[$0]?.first.flatMap { Self.time($0.packet) } ?? .infinity
      let rhs = tracks[$1]?.first.flatMap { Self.time($0.packet) } ?? .infinity
      return lhs == rhs ? $0.rawValue < $1.rawValue : lhs < rhs
    }) else { return }
    guard var entries = tracks.removeValue(forKey: track), !entries.isEmpty else { return }
    bytes -= entries.removeFirst().packet.data.count
    if videoTracks.contains(track) {
      while let first = entries.first, !first.packet.isKeyframe {
        bytes -= entries.removeFirst().packet.data.count
      }
    }
    if !entries.isEmpty { tracks[track] = entries }
  }


  /// A moving head avoids shifting every retained audio packet on each
  /// eviction. Vacated slots release their payload immediately; compaction
  /// amortizes the metadata movement and bounds unused slots.
  private struct Track {
    private var storage: [Entry?] = []
    private var head = 0
    private(set) var bytes = 0
    var isEmpty: Bool { head == storage.count }
    var first: Entry? { isEmpty ? nil : storage[head] }
    var last: Entry? { storage.last ?? nil }
    var snapshot: [Entry] { storage[head...].compactMap { $0 } }

    mutating func append(_ entry: Entry) {
      storage.append(entry)
      bytes += entry.packet.data.count
    }

    mutating func removeFirst() -> Entry {
      let entry = storage[head]!
      storage[head] = nil
      head += 1
      bytes -= entry.packet.data.count
      if isEmpty {
        storage.removeAll()
        head = 0
      } else if head >= 1024, head >= storage.count / 2 {
        storage.removeFirst(head)
        head = 0
      }
      return entry
    }
  }

  /// Decode order, not presentation order: reordered pictures may have PTS
  /// going backwards. Unknown spans or changed parameter generations cannot
  /// prove a continuous replay and deliberately fall back to ordinary seek.
  static func time(_ packet: DemuxPacket) -> Double? {
    if packet.decodeTime.isNumeric { return packet.decodeTime.seconds }
    return packet.presentationTime.isNumeric ? packet.presentationTime.seconds : nil
  }

  static func follows(_ next: DemuxPacket, after previous: DemuxPacket) -> Bool {
    guard previous.decoderParameters === next.decoderParameters,
          let before = time(previous), let after = time(next),
          previous.duration.isNumeric, previous.duration.seconds > 0 else { return false }
    // Container time bases can round independently by a tick, but a coarse
    // clock must not hide a whole missing frame. Cap tolerance below half a
    // packet and reject duplicate decode times as well.
    let tick = max(1 / Double(max(1, previous.decodeTime.isNumeric
                               ? previous.decodeTime.timescale : previous.presentationTime.timescale)),
                   1 / Double(max(1, next.decodeTime.isNumeric
                               ? next.decodeTime.timescale : next.presentationTime.timescale)))
    let tolerance = min(tick + 0.000001, previous.duration.seconds / 4)
    return after > before && abs(after - (before + previous.duration.seconds)) <= tolerance
  }

  static func isContinuous(_ entries: ArraySlice<Entry>) -> Bool {
    guard !entries.isEmpty else { return false }
    for (previous, next) in zip(entries, entries.dropFirst()) {
      if !follows(next.packet, after: previous.packet) { return false }
    }
    return true
  }
}
