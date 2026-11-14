import CoreMedia
import Foundation

/// Where a seek into cached packets would start each queue: the same
/// choices reading after a seek makes (`PrerollFilter`), made on what is
/// queued already. Pictures start at the last key frame at or before the
/// target, sound a warm-up before it; either is refused unless the queue
/// runs from before the target to past it.
enum SeekEntry {
    typealias Entry = (packet: DemuxPacket, seconds: Double)

    /// The last keyframe at or before `time`, when some picture reaches it.
    static func pictureStart(in queue: [Entry], at time: Double) -> Int? {
        guard queue.contains(where: { start(of: $0.packet).map { $0 >= time } == true }) else { return nil }
        return queue.lastIndex { $0.packet.isKeyframe && start(of: $0.packet).map { $0 <= time } == true }
    }

    /// The first packet sounding within the warm-up before `time`, when the
    /// queue starts at or before it and sounds past it.
    static func soundStart(in queue: [Entry], at time: Double) -> Int? {
        guard let first = queue.first.flatMap({ start(of: $0.packet) }), first <= time,
              let last = queue.last.flatMap({ end(of: $0.packet) }), last >= time else { return nil }
        return queue.firstIndex { (end(of: $0.packet) ?? -.infinity) > time - PrerollFilter.audioWarmUp }
    }

    static func start(of packet: DemuxPacket) -> Double? {
        packet.presentationTime.isNumeric ? packet.presentationTime.seconds : nil
    }

    static func end(of packet: DemuxPacket) -> Double? {
        let length = packet.duration.isNumeric ? max(0, packet.duration.seconds) : 0
        return start(of: packet).map { $0 + length }
    }
}
