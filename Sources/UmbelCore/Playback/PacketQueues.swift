import Foundation

/// `PacketCache`'s queues, one per track in the order read, kept in step
/// with its level: whatever goes into a queue or leaves it is counted on or
/// off the level as it does.
internal struct PacketQueues {
    typealias Entry = SeekEntry.Entry
    /// Each packet's contribution is worked out once, on arrival, and stored
    /// with it. Recomputing on the way out would read a `lastAudioTime` that
    /// has since moved on, and the level would drift.
    private var queues: [UmbelTrack.ID: [Entry]] = [:]
    private(set) var level: PacketCacheLevel

    init(level: PacketCacheLevel) {
        self.level = level
    }

    var all: [UmbelTrack.ID: [Entry]] { queues }
    var tracks: [UmbelTrack.ID] { Array(queues.keys) }
    subscript(track: UmbelTrack.ID) -> [Entry] { queues[track] ?? [] }
    func contains(_ track: UmbelTrack.ID) -> Bool { queues[track] != nil }
    func isEmpty(_ track: UmbelTrack.ID) -> Bool { queues[track]?.isEmpty ?? true }

    mutating func append(_ packet: DemuxPacket) {
        let seconds = level.contribution(of: packet)
        queues[packet.trackID, default: []].append((packet, seconds))
        level.add(bytes: packet.data.count, seconds: seconds)
        level.noteByteLimit()
    }

    mutating func prepend(_ entries: [Entry], to track: UmbelTrack.ID) {
        queues[track] = entries + (queues[track] ?? [])
        for entry in entries { level.add(bytes: entry.packet.data.count, seconds: entry.seconds) }
    }

    mutating func replace(_ track: UmbelTrack.ID, with entries: ArraySlice<Entry>) {
        for entry in queues[track] ?? [] { remove(entry) }
        queues[track] = Array(entries)
        for entry in entries { level.add(bytes: entry.packet.data.count, seconds: entry.seconds) }
    }

    mutating func removeFirst(of track: UmbelTrack.ID) -> Entry? {
        guard var queue = queues[track], !queue.isEmpty else { return nil }
        let entry = queue.removeFirst()
        queues[track] = queue
        remove(entry)
        return entry
    }

    mutating func removeFirst(_ count: Int, of track: UmbelTrack.ID) -> [Entry] {
        guard var queue = queues[track] else { return [] }
        let removed = Array(queue[..<count])
        queue.removeFirst(count)
        queues[track] = queue
        for entry in removed { remove(entry) }
        return removed
    }

    /// The packets from the front of `track`'s queue for as long as `condition` holds.
    mutating func removeLeading(of track: UmbelTrack.ID, while condition: (Entry) -> Bool) -> [Entry] {
        guard var queue = queues[track] else { return [] }
        var removed: [Entry] = []
        while let first = queue.first, condition(first) {
            let entry = queue.removeFirst()
            remove(entry)
            removed.append(entry)
        }
        queues[track] = queue
        return removed
    }

    /// The whole of `track`'s queue, the track then gone from the queues.
    mutating func removeAll(of track: UmbelTrack.ID) -> [Entry] {
        let removed = queues.removeValue(forKey: track) ?? []
        for entry in removed { remove(entry) }
        return removed
    }

    mutating func removeAll() {
        queues.removeAll()
        level.reset()
    }

    /// The level measured by `track` from now on: what is queued is counted again.
    mutating func measure(_ track: UmbelTrack.ID?) {
        level.measure(track)
        for (id, queue) in queues {
            var counted: [Entry] = []
            for entry in queue {
                let seconds = level.contribution(of: entry.packet)
                level.add(bytes: 0, seconds: seconds)
                counted.append((entry.packet, seconds))
            }
            queues[id] = counted
        }
    }

    mutating func setGatesPlayback(_ gates: Bool) { level.gatesPlayback = gates }
    mutating func noteByteLimit() { level.noteByteLimit() }
    mutating func markEnd() { level.markEnd() }

    private mutating func remove(_ entry: Entry) {
        level.remove(bytes: entry.packet.data.count, seconds: entry.seconds)
    }
}
