import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Packets read ahead of the decoders, bounded by content duration and an
/// optional compressed payload budget shared by every forward track queue.
/// Consumed media can be retained under a separate backward payload budget.
///
/// One queue per track, so each chain takes its own packets without waiting
/// behind another's: video decodes ahead on its own terms, however full the
/// audio output is.
///
/// Duration counts one track alone: audio when there is one, since mixing
/// tracks makes the level jump around. Without audio it is the video track —
/// measuring nothing would hold the level at zero and never let playback start.
/// With neither there is nothing to wait for.
internal actor PacketCache {
    private let configuration: BufferingConfiguration
    /// The queues, and the level they make; see `PacketQueues`.
    private var queues: PacketQueues
    /// Subtitle tracks, whose recent past is kept; see `routeSubtitles(to:)`.
    private let subtitleTracks: Set<UmbelTrack.ID>
    private var history = SubtitleHistory()
    private var backward: BackwardPacketHistory
    internal private(set) var cacheMissReason = "none"
    /// Spared from pruning whatever selection a caller of `take` still holds.
    private var routedSubtitles: Set<UmbelTrack.ID> = []
    /// The tracks some chain takes; see `select(_:revision:)`.
    private var selectedTracks: Set<UmbelTrack.ID>?
    private var selectionRevision = Int.min
    /// What was let go of unread since the cache was last emptied; see `dropped(_:after:)`.
    private var gaps = PacketGaps()
    /// Sound the system player takes as it asks for it; see `isFull`.
    private var takenOnDemand: UmbelTrack.ID?
    private var cachedAudio: CachedAudioStore
    /// The packet taken last of the sound taken on demand, kept in hand; see `putBackLast(of:)`.
    private var lastTaken: (packet: DemuxPacket, seconds: Double)?

    internal init(
        configuration: BufferingConfiguration, measuredTrack: UmbelTrack.ID?,
        videoTracks: Set<UmbelTrack.ID> = [],
        subtitleTracks: Set<UmbelTrack.ID> = [],
        audioTracks: Set<UmbelTrack.ID> = [],
        cachedAudio: CachedAudioConfiguration = .init(),
        audioParameters: [UmbelTrack.ID: FFmpegCodecParameters] = [:]
    ) {
        self.configuration = configuration
        self.queues = PacketQueues(level: PacketCacheLevel(configuration: configuration, measuredTrack: measuredTrack))
        self.backward = BackwardPacketHistory(
            maximumBytes: configuration.maximumBackwardPacketBytes, videoTracks: videoTracks)
        self.subtitleTracks = subtitleTracks
        self.cachedAudio = CachedAudioStore(
            configuration: cachedAudio, audioTracks: audioTracks,
            initialParameters: audioParameters)
    }

    internal var bufferedSeconds: Double { queues.level.seconds }
    internal var bufferedPacketBytes: Int { queues.level.bytes }
    internal var backwardPacketBytes: Int { backward.bytes }

    /// A newly installed decoder needs all packets that can affect its
    /// current display, even when its track was inactive during a rewind.
    internal func canReplaySubtitles(_ requirements: [UmbelTrack.ID: SubtitleReplayRequirement]) -> Bool {
        requirements.allSatisfy { track, requirement in
            requirement.time.isNumeric && history.canReplay(
                track, at: requirement.time.seconds, requiresCompleteHistory: requirement.requiresCompleteHistory)
        }
    }

    /// Atomically validates all selected media before moving any payloads.
    /// Transferring history can exceed the forward reading high-water mark,
    /// but does not increase total retained payload; reading waits for drain.
    internal func rewind(
        to target: CMTime, video: UmbelTrack.ID?, audio: UmbelTrack.ID?,
        subtitleRequirements: [UmbelTrack.ID: SubtitleReplayRequirement] = [:]
    ) -> Bool {
        cacheMissReason = "historyUnavailable"
        guard configuration.maximumBackwardPacketBytes > 0 else {
            cacheMissReason = "historyDisabled"
            return false
        }
        guard target.isNumeric, video != nil || audio != nil, takenOnDemand == nil else { return false }
        let candidates: [UmbelTrack.ID: (entries: [SeekEntry.Entry], start: Int)]
        switch backward.planRewind(
            to: target.seconds, video: video, audio: audio, queues: queues.all,
            dropped: { gaps.dropped($0, after: target.seconds) }) {
        case .replay(let plan): candidates = plan
        case .miss(let reason):
            cacheMissReason = reason
            return false
        }
        guard Set(subtitleRequirements.keys) == routedSubtitles else {
            cacheMissReason = "subtitleRouteChanged"
            return false
        }
        guard canReplaySubtitles(subtitleRequirements) else {
            cacheMissReason = "subtitleHistoryIncomplete"
            return false
        }
        for (track, plan) in candidates {
            backward.remove(track)
            queues.replace(track, with: plan.entries[plan.start...])
            for entry in plan.entries[..<plan.start] { backward.append(entry) }
        }
        for track in routedSubtitles {
            queues.prepend(history.takeForReplay(track).map { (packet: $0, seconds: 0.0) }, to: track)
        }
        gaps.rewound(replaying: Set(candidates.keys))
        queues.noteByteLimit()
        cacheMissReason = "none"
        return true
    }

    /// Where each track's queue starts and ends, for the diagnostics of a seek
    /// deciding whether it can keep them. Tracks with no timed packet are left out.
    internal var queueSpans: [UmbelTrack.ID: ClosedRange<Double>] {
        queues.all.compactMapValues { queue in
            guard let first = queue.lazy.compactMap({ SeekEntry.start(of: $0.packet) }).first,
                  let last = queue.last.flatMap({ SeekEntry.end(of: $0.packet) }) else { return nil }
            return first...max(first, last)
        }
    }

    internal var reachedByteLimit: Bool { queues.level.reachedByteLimit }

    /// Audio and video no chain takes are dropped first at the byte limit;
    /// switched to later, they are read again (`dropped(_:after:)`).
    /// Subtitles stay: they are small, and a track switched to needs the
    /// line on screen. A subtitle-only queue has no media horizon to drain
    /// it, though; those cues go to reach media data. Selected audio and
    /// video compressed streams always stay intact.
    internal func prepareToRead() -> Bool {
        releaseInactivePacketsAtByteLimit()
        return !isFull
    }

    private func releaseInactivePacketsAtByteLimit() {
        if reachedByteLimit, let selectedTracks {
            for track in queues.tracks where !selectedTracks.contains(track) && !subtitleTracks.contains(track) {
                backward.remove(track)
                for entry in queues.removeAll(of: track) {
                    guard entry.packet.presentationTime.isNumeric else { continue }
                    gaps.drop(track, through: entry.packet.presentationTime.seconds)
                }
            }
            let mediaQueued = queues.all.contains { !subtitleTracks.contains($0.key) && !$0.value.isEmpty }
            if reachedByteLimit, !mediaQueued {
                for track in queues.tracks where subtitleTracks.contains(track) {
                    for entry in queues.removeAll(of: track) { history.discarded(entry.packet) }
                }
            }
        }
    }

    /// Byte pressure always bounds reading. Sound taken on demand bypasses
    /// the duration target while its queue is empty, but not the byte limit.
    internal var isFull: Bool {
        if reachedByteLimit { return true }
        guard queues.level.reachedTarget else { return false }
        guard let takenOnDemand else { return true }
        return !queues.isEmpty(takenOnDemand)
    }
    internal var isWaitingForDemandedAudioAtByteLimit: Bool {
        reachedByteLimit && takenOnDemand.map { queues.isEmpty($0) } == true
    }

    /// Judged by the level, from whether the measured track has anything queued.
    internal var hasEnoughToPlay: Bool { queues.level.hasEnoughToPlay(measuredQueueIsEmpty: measuredQueueIsEmpty) }
    internal var hasEnoughToResume: Bool { queues.level.hasEnoughToResume(measuredQueueIsEmpty: measuredQueueIsEmpty) }
    internal var isStarving: Bool { queues.level.isStarving(measuredQueueIsEmpty: measuredQueueIsEmpty) }
    internal var hasReachedEnd: Bool { queues.level.reachedEnd }
    internal var playbackReadiness: (isStarving: Bool, canStart: Bool, canResume: Bool, atByteLimit: Bool) {
        queues.level.readiness(measuredQueueIsEmpty: measuredQueueIsEmpty)
    }
    private var measuredQueueIsEmpty: Bool { queues.level.measuredTrack.map { queues.isEmpty($0) } ?? true }

    /// Everything read, and nothing of this track left to take.
    internal func isAtEnd(of track: UmbelTrack.ID) -> Bool {
        queues.level.reachedEnd && queues.isEmpty(track)
    }

    @discardableResult
    internal func append(_ packet: DemuxPacket) -> Bool {
        releaseInactivePacketsAtByteLimit()
        guard !reachedByteLimit else { return false }
        cachedAudio.append(packet)
        queues.append(packet)
        return true
    }

    /// The next packet of `track`, in the order read.
    ///
    /// Tracks outside `selected` are pruned behind it: no chain takes them.
    /// A later switch after rewinding rereads the recorded gaps. Without this
    /// an unselected audio track would pile up until the cache counted itself
    /// full of packets nobody will play.
    internal func take(
        from track: UmbelTrack.ID, keeping selected: Set<UmbelTrack.ID>
    ) -> DemuxPacket? {
        guard let entry = queues.removeFirst(of: track) else { return nil }
        retain(entry)
        if track == takenOnDemand { lastTaken = entry }
        if entry.packet.presentationTime.isValid {
            prune(before: entry.packet.presentationTime.seconds, sparing: selected.union([track]))
        }
        return entry.packet
    }

    /// Packets of `track` due by `time` — for subtitles, handed on as the
    /// leading chain gets to them. Packets without a time go at once.
    internal func take(from track: UmbelTrack.ID, upTo time: CMTime) -> [DemuxPacket] {
        guard queues.contains(track) else { return [] }
        let due = queues.removeLeading(of: track) {
            !$0.packet.presentationTime.isValid || $0.packet.presentationTime <= time
        }.map { $0.packet }
        for packet in due { remember(packet) }
        if time.isNumeric { history.forget(before: time.seconds) }
        return due
    }

    /// Routes subtitles to `track` and returns its recent past: the last ten
    /// seconds of it that have left the cache — taken by a decoder, or pruned
    /// while no one wanted it — and older lines still showing by then.
    ///
    /// A line on screen started before the playhead, so a track switched to
    /// mid-play needs its recent past, not only what is ahead: without it the
    /// line showing now appeared only with the next one. Subtitle packets are
    /// small enough to keep that past for every track.
    ///
    /// From here on the track is spared from pruning, even by a chain still
    /// holding the selection from before the switch; otherwise packets could
    /// leave the queue after this has returned and never reach the new
    /// receiver.
    internal func routeSubtitles(to track: UmbelTrack.ID?) -> [DemuxPacket] {
        guard let track else {
            routedSubtitles = []
            return []
        }
        return routeSubtitles(to: [track])[track] ?? []
    }

    internal func routeSubtitles(to tracks: Set<UmbelTrack.ID>) -> [UmbelTrack.ID: [DemuxPacket]] {
        routedSubtitles = tracks
        return history.packets(of: tracks)
    }

    /// Drops `track`'s packets ahead of its last keyframe at or before
    /// `time`, for decoding too far behind to catch up frame by frame; see
    /// `VideoCatchUp`. Returns how many went: none when no such keyframe is
    /// buffered past the first packet.
    internal func skipToKeyframe(of track: UmbelTrack.ID, atOrBefore time: CMTime) -> Int {
        guard let keyframe = queues[track].lastIndex(where: {
                  $0.packet.isKeyframe && $0.packet.presentationTime.isValid
                      && $0.packet.presentationTime <= time
              }),
              keyframe > 0 else { return 0 }
        for entry in queues.removeFirst(keyframe, of: track) { retain(entry) }
        return keyframe
    }

    /// A seek forward into what is read already: the queues of `video` and
    /// `audio` move on to `target` as reading after a seek would have them
    /// (`PrerollFilter`) — pictures from their last keyframe at or before it,
    /// sound from a warm-up before it. Only when each queue runs from before
    /// the target to past it and lost nothing past it at the byte limit;
    /// otherwise nothing changes. Returns whether they moved on.
    internal func skipAhead(to target: CMTime, video: UmbelTrack.ID?, audio: UmbelTrack.ID?) -> Bool {
        guard target.isNumeric, video != nil || audio != nil else { return false }
        var starts: [UmbelTrack.ID: Int] = [:]
        for (track, start) in [(video, SeekEntry.pictureStart), (audio, SeekEntry.soundStart)] {
            guard let track else { continue }
            guard !dropped(track, after: target),
                  let index = start(queues[track], target.seconds) else { return false }
            starts[track] = index
        }
        for (track, start) in starts where start > 0 {
            for entry in queues.removeFirst(start, of: track) { retain(entry) }
        }
        return true
    }

    /// Puts back the packet last taken of `track`, if it is the sound taken on
    /// demand, and returns where its queue then starts. A seek can stop the
    /// feeder mid-handover, the packet then in the store or lost on the way;
    /// given again, the store takes it once. Back once, until the cache is emptied.
    internal func putBackLast(of track: UmbelTrack.ID?) -> CMTime? {
        guard let track else { return nil }
        if let entry = lastTaken, entry.packet.trackID == track, track == takenOnDemand {
            lastTaken = nil
            queues.prepend([entry], to: track)
        }
        return queues[track].first?.packet.presentationTime
    }

    /// Whether packets of `track` after `time` were discarded, either under
    /// byte pressure or while the track was inactive farther along the timeline.
    internal func dropped(_ track: UmbelTrack.ID, after time: CMTime) -> Bool {
        time.isNumeric && gaps.dropped(track, after: time.seconds)
    }

    internal func flush() {
        queues.removeAll()
        backward.removeAll()
        lastTaken = nil
        gaps.removeAll()
        history.removeAll()
        cachedAudio.removeAll()
    }

    /// The tracks some chain takes, as routing `revision` has them; at the
    /// byte limit the others are dropped first. A selection arriving after a
    /// later one changes nothing.
    internal func select(_ tracks: Set<UmbelTrack.ID>, revision: Int) {
        guard revision >= selectionRevision else { return }
        selectionRevision = revision
        if let selectedTracks,
           selectedTracks.subtracting(subtitleTracks) != tracks.subtracting(subtitleTracks) {
            backward.removeAll()
        }
        selectedTracks = tracks
    }

    /// The level is then that track's own: what it has queued, counted
    /// again. Left as it was, packets of the track before — which nobody may
    /// take any more — held reading back.
    internal func setMeasuredTrack(
        _ id: UmbelTrack.ID?, gatesPlayback: Bool = true, takenOnDemand: UmbelTrack.ID? = nil
    ) {
        queues.setGatesPlayback(gatesPlayback)
        if queues.level.measuredTrack != id || self.takenOnDemand != takenOnDemand { backward.removeAll() }
        self.takenOnDemand = takenOnDemand
        guard id != queues.level.measuredTrack else { return }
        queues.measure(id)
    }

    internal func markEndOfContent() {
        queues.markEnd()
    }

    internal func cachedAudioRanges(for track: UmbelTrack.ID) -> [CMTimeRange] {
        cachedAudio.ranges(for: track)
    }

    internal func snapshotAudio(for track: UmbelTrack.ID, range: CMTimeRange) throws -> AudioPacketSnapshot {
        try cachedAudio.snapshot(for: track, range: range)
    }

    private func prune(before time: Double, sparing kept: Set<UmbelTrack.ID>) {
        for id in queues.tracks where !kept.contains(id) && !routedSubtitles.contains(id) {
            let pruned = queues.removeLeading(of: id) {
                $0.packet.presentationTime.isValid && $0.packet.presentationTime.seconds < time
            }
            for entry in pruned {
                backward.remove(id)
                remember(entry.packet)
                if configuration.maximumBackwardPacketBytes > 0, !subtitleTracks.contains(id) {
                    gaps.prune(id, through: SeekEntry.end(of: entry.packet) ?? entry.packet.presentationTime.seconds)
                }
            }
        }
        history.forget(before: time)
    }

    private func retain(_ entry: SeekEntry.Entry) {
        guard takenOnDemand == nil, !subtitleTracks.contains(entry.packet.trackID),
              selectedTracks?.contains(entry.packet.trackID) != false else { return }
        backward.append(entry)
    }

    private func remember(_ packet: DemuxPacket) {
        guard subtitleTracks.contains(packet.trackID) else { return }
        history.remember(packet)
    }
}
