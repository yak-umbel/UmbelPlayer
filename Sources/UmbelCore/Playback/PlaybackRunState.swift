import CoreMedia
import Foundation

/// Whether the clock and the audio output run.
///
/// Wanting to play and being able to are separate: the session records the
/// first, the cache level and the outputs' first frames decide the second,
/// and the clock and the output run only when both hold — the time base
/// stands still while waiting to play.
///
/// Its own actor, apart from the pipeline that moves packets: this decides,
/// that carries. What the cache measures is decided here too, and what
/// reading stopped at its byte budget calls for; see `BytePressureRelief`.
internal actor PlaybackRunState {
    /// How often a route that may need its sound back is looked at while
    /// reading stays stopped: nothing else moves then to have it looked at.
    private static let fallbackPoll: UInt64 = 100_000_000
    /// How long it must stay stuck first. Stuck for real, nothing moves at
    /// all; reading stopped only until a queue drains a little moves again
    /// within a few frames, and falling back would lose the system player
    /// for the rest of the session.
    private static let fallbackPatience = 0.3

    private let clock: PresentationClock
    private let audioOutput: (any AudioOutput)?
    private let cache: PacketCache

    private var wantsToPlay = false
    /// An audio track is being played. A host passes an output whatever the
    /// film; without sound it has nothing to play, is never prepared, and
    /// is left alone — started, it would refuse and fail the film.
    private var hasSound = false
    /// Played to the end: the clock stands on it, whatever the host asks,
    /// until a seek.
    private var isEnded = false
    private var rebuffer = RebufferGate()
    /// Every output has a first frame to start with; see `FirstFrameWait`.
    private var outputsReady = false
    private var firstFrames = FirstFrameWait()
    /// The system player that plays the sound, when one does, leads the
    /// clock; it cannot before it is ready. See `AudioPath`.
    private var soundReady = true
    private var relief = BytePressureRelief()
    /// What the clock and the output were last told. Tracked separately from
    /// what they should be, so that convergence can tell whether it has work.
    private var appliedRunning = false
    private var isConverging = false
    private var updateGeneration: UInt64 = 0
    /// How fast playing goes; the clock runs at it while running.
    private var rate = 1.0

    internal init(clock: PresentationClock, audioOutput: (any AudioOutput)?, cache: PacketCache) {
        self.clock = clock
        self.audioOutput = audioOutput
        self.cache = cache
    }

    /// Held back for data, or for the outputs' first frames. Reported as
    /// buffering only while wanting to play; paused is paused, however little
    /// is buffered.
    internal var isRebuffering: Bool { rebuffer.isHolding || !outputsReady || !soundReady }
    internal var isRunning: Bool {
        wantsToPlay && !rebuffer.isHolding && outputsReady && soundReady && !isEnded
    }

    /// The host's intent.
    internal func setWantsToPlay(_ wants: Bool) async throws {
        wantsToPlay = wants
        try await converge()
    }

    /// Looks at the cache again and starts or stops the clock accordingly.
    /// Throws when the output refuses to start.
    internal func update() async throws {
        updateGeneration &+= 1
        let generation = updateGeneration
        var readiness = await cache.playbackReadiness
        if readiness.atByteLimit, try await relieveBytePressure() {
            readiness = await cache.playbackReadiness
        }
        // A newer observation (or a seek hold) supersedes this one while
        // suspended. An older cache state must not overwrite the newer gate.
        guard generation == updateGeneration else { return }
        guard rebuffer.update(
            isStarving: readiness.isStarving,
            hasEnoughToStart: readiness.canStart, hasEnoughToResume: readiness.canResume
        ) else { return }
        try await converge()
    }

    /// The cache was emptied on purpose — a seek. Wait for it to refill.
    internal func hold() async {
        updateGeneration &+= 1
        isEnded = false
        rebuffer.hold()
        try? await converge()
    }

    /// Whether every output has a first frame to start with. Throws when
    /// the output refuses to start.
    internal func setOutputsReady(_ ready: Bool) async throws {
        outputsReady = ready
        try await converge()
    }

    /// Playback starts, at first and after each seek: the outputs of
    /// `tracks` wait for a first frame, playback starting at `origin`, and
    /// none has handed one on yet.
    internal func restart(awaiting tracks: Set<UmbelTrack.ID>, from origin: CMTime) async throws {
        firstFrames = FirstFrameWait(awaiting: tracks, from: origin)
        relief.restart()
        try await setOutputsReady(firstFrames.isReady)
    }

    /// `frames` of what `packet` decoded to went to its output.
    internal func handedOn(_ packet: DemuxPacket, frames: Int) async throws {
        if firstFrames.firstFrame(from: packet.trackID, handingOn: frames), relief.firstFrame(of: packet.trackID) {
            await measure()
        }
        if firstFrames.decoded(packet, handingOn: frames) { try await setOutputsReady(true) }
    }

    /// `track` has handed on all it ever will.
    internal func finished(_ track: UmbelTrack.ID) async throws {
        if firstFrames.finished(track) { try await setOutputsReady(true) }
    }

    /// Only `routed` tracks are waited for: one switched off has nothing more to hand on.
    internal func awaitFirstFrames(only routed: Set<UmbelTrack.ID>) async throws {
        if firstFrames.keep(only: routed) { try await setOutputsReady(true) }
    }

    /// Whether the player playing the sound is ready to lead the clock. Its
    /// sound then counts as a first frame at the byte budget.
    internal func setSoundReady(_ ready: Bool) async throws {
        soundReady = ready
        try await converge()
        try await update()
    }

    /// A route, published as `revision`: which tracks the cache keeps, what
    /// it measures by, and whether there is sound. `routed` are the tracks
    /// whose outputs wait for a first frame. A route arriving after a later
    /// one changes nothing.
    internal func route(_ routing: PacketRouting, routed: Set<UmbelTrack.ID>, revision: Int) async {
        guard relief.route(routing, routed: routed, revision: revision) else { return }
        await cache.select(routing.selectedTracks, revision: revision)
        await measure()
        await setHasSound(relief.routing.hasSound)
    }

    /// The output was reconfigured underneath a running session — a track
    /// switch. Start it again if it is meant to be running.
    internal func restartOutputIfRunning() async throws {
        guard appliedRunning else { return }
        try await audioOutput?.start()
    }

    /// Playback reached `end`: the output and the clock stop, the clock on
    /// the end itself rather than wherever it had run on to.
    internal func stopAtEnd(_ end: CMTime) async {
        isEnded = true
        try? await converge()
        await clock.stop(at: end)
    }

    /// A new rate. The output always plays at it, ready for when it starts;
    /// the clock takes it at once while running, settling what went before
    /// at the old one.
    internal func setRate(_ rate: Double) async {
        self.rate = rate
        await audioOutput?.setRate(rate)
        if appliedRunning { await clock.setRate(rate) }
    }

    /// Sound was turned on or off. Turned off while running, the output
    /// pauses; turned on, it starts once it has been prepared for the new
    /// track — `restartOutputIfRunning()`, which a track switch calls.
    private func setHasSound(_ sound: Bool) async {
        guard sound != hasSound else { return }
        hasSound = sound
        if !sound, appliedRunning { await audioOutput?.pause() }
    }

    private func measure() async {
        let level = relief.measurement
        await cache.setMeasuredTrack(
            level.track, gatesPlayback: level.gatesPlayback, takenOnDemand: level.takenOnDemand)
    }

    /// Reading has stopped at the byte budget; see `BytePressureRelief`.
    /// Returns whether what the cache measures by may have changed.
    private func relieveBytePressure() async throws -> Bool {
        var remeasured = false
        if !outputsReady, relief.relieve(soundReady: soundReady) {
            await measure()
            remeasured = true
            try await setOutputsReady(true)
        }
        if outputsReady, relief.mayAskForFallback, await cache.isWaitingForDemandedAudioAtByteLimit,
           let request = relief.askForFallback() {
            // Falling back seeks, which stops the pipeline: apart from the
            // reader and the feeders that stopping waits for.
            Task { [weak self] in await self?.fallBack(request) }
        }
        return remeasured
    }

    /// Looks until the route has been stuck long enough and gives the sound
    /// back, or reading goes on, or the request no longer stands, or the
    /// route closes.
    private func fallBack(_ request: BytePressureRelief.FallbackRequest) async {
        defer { relief.settle(request) }
        var watch = StallWatch(patience: Self.fallbackPatience)
        while await stillStuck(request), !(await request.route.isClosed) {
            let stuck = await request.route.isStuckAtPacketLimit
            if watch.look(stuck: stuck, at: ProcessInfo.processInfo.systemUptime),
               await request.route.fallBackAtPacketLimit(stillWanted: { [weak self] in
                   await self?.stillStuck(request) ?? false
               }) {
                return
            }
            try? await Task.sleep(nanoseconds: Self.fallbackPoll)
        }
    }

    /// Asked again after every wait: a seek or another route meanwhile
    /// leaves the request standing for nothing.
    private func stillStuck(_ request: BytePressureRelief.FallbackRequest) async -> Bool {
        guard relief.holds(request) else { return false }
        let waiting = await cache.isWaitingForDemandedAudioAtByteLimit
        return waiting && relief.holds(request)
    }

    /// Brings the clock and the output in line with `isRunning`.
    ///
    /// Only one pass runs at a time, and it loops until nothing changed while
    /// it was suspended. Two interleaved passes could otherwise finish in the
    /// wrong order and leave the output playing under a stopped clock.
    private func converge() async throws {
        guard !isConverging else { return }
        isConverging = true
        defer { isConverging = false }
        while appliedRunning != isRunning {
            let target = isRunning
            if target {
                if hasSound { try await audioOutput?.start() }
                await clock.setRate(rate)
            } else {
                await audioOutput?.pause()
                await clock.setRate(0)
            }
            appliedRunning = target
        }
    }
}
