import Foundation

/// How full `PacketCache` is, and what that allows: the buffered duration of
/// the one track the level is measured by, the compressed payload bytes of
/// every queue, and whether those let playback start, resume or go on.
///
/// The cache keeps its queues; it tells the level what arrives and leaves,
/// and whether the measured track has anything queued when that matters.
internal struct PacketCacheLevel {
    private let configuration: BufferingConfiguration
    /// Which track the level is measured from. Changes when the selection
    /// does — measuring against a track that is no longer being fed would make
    /// the level drift away from what is actually buffered.
    private(set) var measuredTrack: UmbelTrack.ID?
    private(set) var seconds: Double = 0
    private(set) var bytes = 0
    /// A capacity-limited refill drains before the time watermark applies
    /// again; otherwise its first dequeue would immediately pause playback.
    private var drainingByteLimitedBuffer = false
    private var lastMeasuredTime: Double?
    private(set) var reachedEnd = false
    /// Whether the level holds playback back, or only bounds reading: not
    /// when the system player plays the sound with no picture to show. It
    /// waits for its own data, and a level measured behind what it already
    /// holds would stop it early.
    var gatesPlayback = true

    init(configuration: BufferingConfiguration, measuredTrack: UmbelTrack.ID?) {
        self.configuration = configuration
        self.measuredTrack = measuredTrack
    }

    var reachedByteLimit: Bool {
        guard let maximum = configuration.maximumPacketBytes else { return false }
        return bytes >= max(1, maximum)
    }

    /// Whether the buffered duration has reached what reading aims for.
    var reachedTarget: Bool { seconds >= configuration.target }

    mutating func add(bytes: Int, seconds: Double) {
        self.bytes += bytes
        self.seconds += seconds
    }

    mutating func remove(bytes: Int, seconds: Double) {
        self.bytes -= bytes
        self.seconds = max(0, self.seconds - seconds)
        if self.bytes == 0 { drainingByteLimitedBuffer = false }
    }

    /// A refill that has reached the byte limit drains before the time
    /// watermark applies again.
    mutating func noteByteLimit() {
        if reachedByteLimit { drainingByteLimitedBuffer = true }
    }

    mutating func markEnd() { reachedEnd = true }

    /// Empty again; the measured track and the gating stay.
    mutating func reset() {
        seconds = 0
        bytes = 0
        drainingByteLimitedBuffer = false
        lastMeasuredTime = nil
        reachedEnd = false
    }

    /// Measures by `track` from now on. The duration starts again from
    /// nothing; the cache counts what it has queued again with `contribution(of:)`.
    mutating func measure(_ track: UmbelTrack.ID?) {
        measuredTrack = track
        drainingByteLimitedBuffer = reachedByteLimit
        lastMeasuredTime = nil
        seconds = 0
    }

    /// Only the measured track counts toward the level; see `PacketCache`.
    ///
    /// Containers that leave duration out would otherwise hold the level at
    /// zero and disable the buffering decision entirely, so a missing duration
    /// falls back to the gap from the previous audio packet.
    mutating func contribution(of packet: DemuxPacket) -> Double {
        guard let measuredTrack, packet.trackID == measuredTrack else { return 0 }
        guard packet.presentationTime.isValid else { return 0 }
        let now = packet.presentationTime.seconds
        defer { lastMeasuredTime = now }
        if packet.duration.isValid, packet.duration.seconds > 0 {
            return packet.duration.seconds
        }
        guard let previous = lastMeasuredTime, now > previous else { return 0 }
        return now - previous
    }

    /// One observation: reading these separately can mix pre-EOF starvation
    /// with post-EOF readiness while the reader and feeders change the cache.
    func readiness(
        measuredQueueIsEmpty empty: Bool
    ) -> (isStarving: Bool, canStart: Bool, canResume: Bool, atByteLimit: Bool) {
        guard gatesPlayback else { return (false, true, true, reachedByteLimit) }
        return (isStarving(measuredQueueIsEmpty: empty), hasEnoughToPlay(measuredQueueIsEmpty: empty),
                hasEnoughToResume(measuredQueueIsEmpty: empty), reachedByteLimit)
    }

    func hasEnoughToPlay(measuredQueueIsEmpty empty: Bool) -> Bool {
        reachedEnd || measuredTrack == nil || hasPlayableByteLimitedBuffer(measuredQueueIsEmpty: empty)
            || seconds >= configuration.startThreshold
    }

    /// Enough to resume after running dry; see `resumeThreshold`.
    func hasEnoughToResume(measuredQueueIsEmpty empty: Bool) -> Bool {
        reachedEnd || measuredTrack == nil || hasPlayableByteLimitedBuffer(measuredQueueIsEmpty: empty)
            || seconds >= min(configuration.resumeThreshold, configuration.target)
    }

    /// Running dry with content still to come. Reaching the end is not
    /// starving — it is simply over.
    func isStarving(measuredQueueIsEmpty empty: Bool) -> Bool {
        guard !reachedEnd, !reachedByteLimit, measuredTrack != nil else { return false }
        if drainingByteLimitedBuffer { return empty }
        return seconds < configuration.lowWatermark
    }

    private func hasPlayableByteLimitedBuffer(measuredQueueIsEmpty empty: Bool) -> Bool {
        reachedByteLimit || (drainingByteLimitedBuffer && !empty)
    }
}
