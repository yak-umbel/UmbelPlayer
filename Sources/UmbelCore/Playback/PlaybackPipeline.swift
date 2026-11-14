import CoreMedia
import Foundation

/// Feeds independent audio/video queues; subtitles follow the leading chain.
/// The session owns routing; `PlaybackRunState` controls the clock.
internal actor PlaybackPipeline {
    private typealias Chain = PacketChain
    private let audioOutput: (any AudioOutput)?
    private let videoRenderer: (any VideoRenderer)?
    private let clock: PresentationClock
    private let cache: PacketCache
    private let reader: PacketReader
    private let run: PlaybackRunState
    private let subtitleFeed: SubtitleFeed
    private let catchUp: VideoCatchUp
    private var routing = PacketRouting.unrouted
    private var routingRevision = 0
    private var videoFeedRevision = 0
    private var feedTasks: [Chain: Task<Void, Never>] = [:]
    private var isFeeding = false
    private var finishedChains: Set<Chain> = []
    private var discardGate = DiscardGate()
    private var outcome = PlaybackOutcome()
    private var playoutEnd = PlayoutEnd()
    private var continuity: AudioContinuity
    private let diagnostics: UmbelPlaybackDiagnostics?
    private var audioTiming = AudioTiming()
    private var endWatch: Task<Void, Never>?

    internal init(
        demux: DemuxSession,
        audioOutput: (any AudioOutput)?,
        videoRenderer: (any VideoRenderer)?,
        clock: PresentationClock,
        cache: PacketCache,
        diagnostics: UmbelPlaybackDiagnostics? = nil
    ) {
        self.audioOutput = audioOutput
        self.videoRenderer = videoRenderer
        self.clock = clock
        self.diagnostics = diagnostics
        self.continuity = AudioContinuity(diagnostics: diagnostics)
        self.cache = cache
        self.reader = PacketReader(demux: demux, cache: cache)
        self.subtitleFeed = SubtitleFeed(cache: cache)
        self.catchUp = VideoCatchUp(cache: cache, clock: clock)
        self.run = PlaybackRunState(clock: clock, audioOutput: audioOutput, cache: cache)
    }

    internal var terminal: UmbelPlaybackPhase? { outcome.phase }
    internal var failureReason: UmbelError? { outcome.failure }
    internal var isRebuffering: Bool { get async { await run.isRebuffering } }
    internal var isRunning: Bool { get async { await run.isRunning } }

    internal func clearTerminal() { outcome.clear() }
    internal func markFailed(_ error: Error) { reportFailure(error) }

    internal func updateRouting(_ routing: PacketRouting) async {
        let previous = self.routing
        self.routing = routing
        let changed = finishedChains.filter { !isCurrent($0, route: previous) }
        finishedChains.subtract(changed)
        // Finished tasks have no further side effects; changed routes need a new feeder, even when idle.
        if isFeeding, !outcome.isSettled, previous.generation == routing.generation {
            for chain in changed { feedTasks[chain] = nil; startFeeding(chain) }
        }
        updatePlayoutWatch()
        if routing.audioSession !== previous.audioSession { continuity.reset(); audioTiming.restart() }
        routingRevision += 1
        let revision = routingRevision
        // Before anything slower: at the byte budget, reading drops the
        // packets of tracks the cache does not know to be selected.
        await run.route(routing, routed: routedTracks(in: routing), revision: revision)
        await subtitleFeed.route(routing.subtitleRoutes)
        guard revision == routingRevision else { return }
        await reportingFailure { try await run.awaitFirstFrames(only: routedTracks(in: routing)) }
    }

    internal func setWantsToPlay(_ wants: Bool) async throws { try await run.setWantsToPlay(wants) }
    internal func setRate(_ rate: Double) async { await run.setRate(rate) }
    internal func setAudioDelay(_ delay: CMTime) { audioTiming.setDelay(delay) }
    internal func restartOutputIfRunning() async throws { try await run.restartOutputIfRunning() }
    internal func setSoundReady(_ ready: Bool) async { await reportingFailure { try await run.setSoundReady(ready) } }
    internal func armDiscardBoth(at time: CMTime) { discardGate.armBoth(at: time) }

    /// After a seek, reading may start before the target; see `PrerollFilter`.
    internal func armPreroll(at target: CMTime, audioFrom audioTarget: CMTime? = nil) async {
        await reader.armPreroll(at: target, audioFrom: audioTarget, video: routing.videoID, audio: routing.audioID)
    }

    /// Starts once; a play after pause retains completed chains.
    internal func start() async {
        await reader.start(
            onRead: { [weak self] in await self?.updateRunState() },
            onEnd: { [weak self] error in await self?.endReading(failedWith: error) })
        guard feedTasks.isEmpty else { return }
        finishedChains = []
        await reportingFailure { try await run.restart(awaiting: routedTracks(in: routing), from: await clock.now()) }
        isFeeding = true
        for chain in Chain.allCases { startFeeding(chain) }
    }

    internal func stop() async {
        await reader.cancel()
        await stopFeeding()
        await reader.waitUntilStopped()
    }

    /// Stops feeding but not reading, for a seek that may keep what is read.
    /// The outputs wait for first frames again: with reading going on, the
    /// level alone would otherwise start the clock where it was.
    internal func stopFeeding() async {
        isFeeding = false
        videoFeedRevision += 1
        endWatch?.cancel()
        endWatch = nil
        for task in feedTasks.values { task.cancel() }
        await videoRenderer?.flush()
        await audioOutput?.flush()
        for task in feedTasks.values { await task.value }
        feedTasks = [:]
        try? await run.restart(awaiting: routedTracks(in: routing), from: await clock.now())
    }

    /// Ordinary forward reuse stays available to every supported audio path.
    /// History replay is limited to engine-decoded sound and complete subtitles.
    internal func seekUsingCache(
        to target: CMTime, subtitleRequirements: [UmbelTrack.ID: SubtitleReplayRequirement]
    ) async -> CacheSeekResult {
        guard !outcome.isSettled, outcome.readFailure == nil else { return .miss("readFailedOrEnded") }
        guard await !reader.isFiltering else { return .miss("seekPreroll") }
        let video = track(for: .video, in: routing)
        let audio = routing.audioSession == nil ? nil : track(for: .audio, in: routing)
        if await routing.objectAudio?.keepReading(
            forSeekTo: target, nextPacketAt: cache.putBackLast(of: routing.audioID)) ?? true,
           await cache.skipAhead(to: target, video: video, audio: audio) {
            await restartPlayout()
            return .forward
        }
        guard routing.objectAudio == nil else { return .miss("systemAudio") }
        guard await cache.rewind(to: target, video: video, audio: audio, subtitleRequirements: subtitleRequirements) else {
            return .miss(await cache.cacheMissReason)
        }
        await restartPlayout()
        return .backward
    }

    internal func flushCache() async {
        await cache.flush()
        await reader.clearPreroll()
        // A seek retries even after a previous read failure.
        outcome.readFailure = nil
        await restartPlayout()
    }

    /// What was handed on belongs to where playback was.
    private func restartPlayout() async {
        await catchUp.reset()
        playoutEnd = PlayoutEnd()
        continuity.reset()
        audioTiming.restart()
        await run.hold()
    }

    private func startFeeding(_ chain: Chain) {
        guard isFeeding, feedTasks[chain] == nil else { return }
        if chain == .video { videoFeedRevision += 1 }
        let cache = self.cache
        let generation = routing.generation

        feedTasks[chain] = Task { [weak self] in
            var horizon = CMTime.negativeInfinity
            while !Task.isCancelled {
                guard let route = await self?.routing, route.generation == generation else { return }
                guard let track = await self?.track(for: chain, in: route) else {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    continue
                }
                let taken = await cache.take(from: track, keeping: route.selectedTracks)
                await self?.updateRunState()
                guard !Task.isCancelled else { return }
                guard await self?.isCurrent(chain, route: route) == true else { continue }
                do {
                    guard let packet = taken else {
                        if await cache.isAtEnd(of: track) {
                            try await self?.finish(chain, route: route)
                            return
                        }
                        try await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    try await self?.deliver(packet, on: chain, route: route)
                } catch {
                    guard !Task.isCancelled else { return }
                    guard await self?.isCurrent(chain, route: route) == true else { continue }
                    await self?.reportFailure(error)
                    return
                }
                guard let packet = taken else { continue }
                if packet.presentationTime.isValid, packet.presentationTime > horizon {
                    horizon = packet.presentationTime
                    await self?.deliverSubtitles(upTo: horizon, from: chain, route: route)
                }
            }
        }
    }

    private func track(for chain: Chain, in route: PacketRouting) -> UmbelTrack.ID? {
        route.track(for: chain, hasAudioOutput: audioOutput != nil, hasVideoRenderer: videoRenderer != nil)
    }

    /// Route identity and seek generation must survive every suspension point.
    private func isCurrent(_ chain: Chain, route: PacketRouting) -> Bool { route.feeds(chain, as: routing) }

    private func checkCurrent(_ chain: Chain, route: PacketRouting) throws {
        try Task.checkCancellation()
        guard isCurrent(chain, route: route) else { throw CancellationError() }
    }

    /// Release renderer backpressure and quiesce video before invalidating its decoder.
    internal func suspendVideoFeeding() async {
        videoFeedRevision += 1
        let revision = videoFeedRevision
        guard let task = feedTasks[.video] else { return }
        task.cancel()
        await videoRenderer?.flush()
        await task.value
        guard revision == videoFeedRevision else { return }
        feedTasks[.video] = nil
        finishedChains.remove(.video)
        await videoRenderer?.flush()
    }

    internal func resumeVideoFeeding() {
        guard !feedTasks.isEmpty else { return }
        startFeeding(.video)
    }

    private func deliver(_ packet: DemuxPacket, on chain: Chain, route: PacketRouting) async throws {
        try checkCurrent(chain, route: route)
        switch chain {
        case .audio:
            if let objectAudio = route.objectAudio {
                // Still encoded, to the system player; its readiness is waited for apart.
                try await objectAudio.take(packet)
                try checkCurrent(chain, route: route)
                return playoutEnd.delivered(packet)
            }
            guard let session = route.audioSession, let output = audioOutput else { return }
            let decoded = try await session.decode(packet)
            try checkCurrent(chain, route: route)
            diagnostics?.recordDecoded(decoded, from: packet, generation: route.generation)
            let frames = audioFramesToDeliver(decoded)
            let emitted = try await enqueueAudio(frames, route: route, output: output)
            await handedOn(packet, frames: emitted)
            await refreshClock()
        case .video:
            guard let session = route.videoSession, let renderer = videoRenderer else { return }
            let hidden = discardGate.hidesVideo(at: packet.presentationTime)
            let decoded = try await session.decode(packet, hidden: hidden)
            try checkCurrent(chain, route: route)
            diagnostics?.recordDecoded(decoded, from: packet, generation: route.generation)
            let frames = discardGate.videoFramesToDeliver(decoded)
            if let track = route.videoID { await catchUp.review(frames, from: session, track: track) }
            try await enqueueVideo(frames, route: route, renderer: renderer)
            await handedOn(packet, frames: frames.filter(\.isShown).count)
        }
    }

    private func enqueueAudio(
        _ frames: [AudioFrame], route: PacketRouting, output: any AudioOutput
    ) async throws -> Int {
        var emitted = 0
        for frame in frames {
            let ready = delayedAudio(frame)
            for item in ready {
                try checkCurrent(.audio, route: route)
                try await output.enqueue(item)
                try checkCurrent(.audio, route: route)
            }
            emitted += ready.count
            playoutEnd.delivered(frame)
        }
        try checkCurrent(.audio, route: route)
        return emitted
    }

    private func enqueueVideo(
        _ frames: [VideoFrame], route: PacketRouting, renderer: any VideoRenderer
    ) async throws {
        for frame in frames {
            try checkCurrent(.video, route: route)
            let recovered = try await VideoPath.deliver(frame, to: renderer, source: route.videoSession,
                validate: { try await self.checkCurrent(.video, route: route) })
            if recovered { return }
            try checkCurrent(.video, route: route)
            playoutEnd.delivered(frame)
        }
        try checkCurrent(.video, route: route)
    }

    private func deliverSubtitles(upTo time: CMTime, from chain: Chain, route: PacketRouting) async {
        guard !Task.isCancelled, isCurrent(chain, route: route), chain == leadingChain(in: route) else { return }
        await subtitleFeed.deliver(upTo: time)
    }

    private func leadingChain(in route: PacketRouting) -> Chain { track(for: .video, in: route) != nil ? .video : .audio }

    private func finish(_ chain: Chain, route: PacketRouting) async throws {
        try checkCurrent(chain, route: route)
        switch chain {
        case .audio:
            if let objectAudio = route.objectAudio { await objectAudio.finishReading() }
            if let audio = route.audioSession, let output = audioOutput {
                let decoded = try await audio.drain()
                try checkCurrent(chain, route: route)
                _ = try await enqueueAudio(audioFramesToDeliver(decoded), route: route, output: output)
            }
        case .video:
            if let video = route.videoSession, let renderer = videoRenderer {
                let decoded = try await video.drain()
                try checkCurrent(chain, route: route)
                try await enqueueVideo(discardGate.videoFramesAtEnd(decoded), route: route, renderer: renderer)
            }
        }
        try checkCurrent(chain, route: route)
        if chain == leadingChain(in: route) {
            await deliverSubtitles(upTo: .positiveInfinity, from: chain, route: route)
        }
        try checkCurrent(chain, route: route)
        if let track = track(for: chain, in: route) { await reportingFailure { try await run.finished(track) } }
        try checkCurrent(chain, route: route)
        finishedChains.insert(chain)
        updatePlayoutWatch()
    }

    /// Routing can remove the last unfinished chain or introduce a new one.
    private func updatePlayoutWatch() {
        endWatch?.cancel()
        endWatch = nil
        let routed = Set(Chain.allCases.filter { track(for: $0, in: routing) != nil })
        guard isFeeding, !routed.isEmpty, routed.isSubset(of: finishedChains), !outcome.isSettled else { return }
        endWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.settleIfPlayedOut() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    private func settleIfPlayedOut() async -> Bool {
        guard !outcome.isSettled else { return true }
        let end = playoutEnd.end ?? .zero
        let audioEnd = track(for: .audio, in: routing) == nil ? .zero : audioTiming.outputEnd
        guard await clock.now() >= max(end, audioEnd) else { return false }
        guard !Task.isCancelled else { return true }
        await run.stopAtEnd(end)
        guard !Task.isCancelled else { return true }
        outcome.playedOut()
        return true
    }

    /// EOF releases the buffering gate; read errors wait for buffered playout.
    private func endReading(failedWith error: Error?) async {
        outcome.readFailure = error
        await cache.markEndOfContent()
        await updateRunState()
    }

    private func reportFailure(_ error: Error) { outcome.fail(error) }

    /// The run state throws when the output refuses to start: playback fails.
    private func reportingFailure(of step: () async throws -> Void) async {
        do { try await step() } catch { reportFailure(error) }
    }

    /// `frames` of what `packet` decoded to went to its output.
    private func handedOn(_ packet: DemuxPacket, frames: Int) async {
        await reportingFailure { try await run.handedOn(packet, frames: frames) }
    }

    /// Sound for the system player has no first frame here; see `setSoundReady(_:)`.
    private func routedTracks(in route: PacketRouting) -> Set<UmbelTrack.ID> {
        Set(Chain.allCases.compactMap { $0 == .audio && route.objectAudio != nil ? nil : track(for: $0, in: route) })
    }

    private func updateRunState() async { await reportingFailure { try await run.update() } }

    private func refreshClock() async {
        guard let anchor = await audioOutput?.currentAnchor else { return }
        await clock.adopt(anchor)
    }

    private func delayedAudio(_ frame: AudioFrame) -> [AudioFrame] { audioTiming.frames(for: frame, systemTimed: audioOutput is any SystemTimelineKeeping) }

    private func audioFramesToDeliver(_ frames: [AudioFrame]) -> [AudioFrame] {
        discardGate.audioFramesToDeliver(frames).flatMap { continuity.frames(for: $0) }
    }
}
