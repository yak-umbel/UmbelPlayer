import Foundation

/// How far packets of each track were let go of before any decoder took
/// them, so that playing that track from before there means reading it again.
internal struct PacketGaps {
    /// Discarded under byte pressure, or carried over by a rewind.
    private var droppedUntil: [UmbelTrack.ID: Double] = [:]
    /// Ordinary switching keeps its existing decode-ahead behavior. These
    /// inactive-track gaps become reread requirements only after a rewind.
    private var prunedUntil: [UmbelTrack.ID: Double] = [:]

    mutating func drop(_ track: UmbelTrack.ID, through time: Double) {
        droppedUntil[track] = max(droppedUntil[track] ?? -.infinity, time)
    }

    mutating func prune(_ track: UmbelTrack.ID, through time: Double) {
        prunedUntil[track] = max(prunedUntil[track] ?? -.infinity, time)
    }

    /// Whether packets of `track` after `time` were dropped.
    func dropped(_ track: UmbelTrack.ID, after time: Double) -> Bool {
        guard let until = droppedUntil[track] else { return false }
        return until > time
    }

    /// A rewind replayed `replayed`; what the other tracks were pruned
    /// through, farther along the timeline, must now be read again.
    mutating func rewound(replaying replayed: Set<UmbelTrack.ID>) {
        for (track, end) in prunedUntil where !replayed.contains(track) { drop(track, through: end) }
    }

    mutating func removeAll() {
        droppedUntil.removeAll()
        prunedUntil.removeAll()
    }
}
