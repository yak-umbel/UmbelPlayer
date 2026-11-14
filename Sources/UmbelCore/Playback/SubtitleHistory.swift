import Foundation

/// Subtitle packets that have left the cache — taken by a decoder, or pruned
/// while no one wanted them — kept for a track switched to mid-play: the line
/// on screen then started before the playhead.
///
/// Ten seconds of them, the same bound as subtitle seek preroll, and older
/// lines that may still be showing by then. Subtitle packets are small
/// enough to keep this for every track.
internal struct SubtitleHistory: Sendable {
  /// How far back it reaches.
  static let reach = 10.0
  /// At most this many lines per track are kept for still showing past that reach.
  static let lineLimit = 32

  private var packets: [UmbelTrack.ID: [DemuxPacket]] = [:]
  /// A discarded cue may still matter before this time. Unknown ends are
  /// conservative: only a normal seek can establish complete history again.
  private var replayFloor: [UmbelTrack.ID: Double] = [:]

  func canReplay(_ track: UmbelTrack.ID, at time: Double, requiresCompleteHistory: Bool = false) -> Bool {
    if requiresCompleteHistory, replayFloor[track] != nil { return false }
    return time >= (replayFloor[track] ?? -.infinity)
  }

  mutating func takeForReplay(_ track: UmbelTrack.ID) -> [DemuxPacket] {
    packets.removeValue(forKey: track) ?? []
  }

  mutating func discarded(_ packet: DemuxPacket) {
    let end = packet.presentationTime.isNumeric && packet.duration.isNumeric && packet.duration > .zero
      ? packet.presentationTime.seconds + packet.duration.seconds : Double.infinity
    replayFloor[packet.trackID] = max(replayFloor[packet.trackID] ?? -.infinity, end)
  }

  mutating func remember(_ packet: DemuxPacket) {
    packets[packet.trackID, default: []].append(packet)
  }

  func packets(of tracks: Set<UmbelTrack.ID>) -> [UmbelTrack.ID: [DemuxPacket]] {
    packets.filter { tracks.contains($0.key) }
  }

  mutating func removeAll() {
    packets.removeAll()
    replayFloor.removeAll()
  }

  /// Drops what is more than its reach behind `time`, except lines that may
  /// still be on screen there; see `stillShowing(_:at:)`.
  mutating func forget(before time: Double) {
    let cutoff = time - Self.reach
    for (id, kept) in packets {
      let result = Self.stillShowing(kept, at: cutoff)
      packets[id] = result.kept
      for packet in result.dropped { discarded(packet) }
    }
  }

  /// The packets of one track that can still matter at `cutoff`: those from
  /// it on, and older lines still showing there. A line with an end shows
  /// until it; one without shows until the next replaces it — as picture
  /// subtitles do — so only the latest of those counts. Lengths come from
  /// the stream, so how many older lines are kept is bounded, newest first.
  private static func stillShowing(
    _ packets: [DemuxPacket], at cutoff: Double
  ) -> (kept: [DemuxPacket], dropped: [DemuxPacket]) {
    func start(_ packet: DemuxPacket) -> Double? {
      packet.presentationTime.isValid ? packet.presentationTime.seconds : nil
    }
    func end(_ packet: DemuxPacket) -> Double? {
      guard let start = start(packet), packet.duration.isValid, packet.duration.seconds > 0 else { return nil }
      return start + packet.duration.seconds
    }
    let openStart = packets.last { end($0) == nil && (start($0) ?? cutoff) < cutoff }.flatMap(start)
    var older = 0
    var dropped: [DemuxPacket] = []
    var kept = packets.filter { packet in
      guard let start = start(packet), start < cutoff else { return true }
      let showing = end(packet).map { $0 > cutoff } ?? (start == openStart)
      if showing { older += 1 } else { dropped.append(packet) }
      return showing
    }
    var excess = older - lineLimit
    if excess > 0 {
      kept.removeAll { packet in
        guard excess > 0, let start = start(packet), start < cutoff else { return false }
        excess -= 1
        dropped.append(packet)
        return true
      }
    }
    return (kept, dropped)
  }
}
