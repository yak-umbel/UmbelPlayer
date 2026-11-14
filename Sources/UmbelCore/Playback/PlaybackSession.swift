import CoreMedia
import Foundation

/// Joins source, demuxing, decoding, output, rendering and clock.
/// Audio and video outputs are optional and independently owned.
public actor PlaybackSession {
  public let videoDecodingMode: UmbelVideoDecodingMode
  /// The decoder asked for when the session was made, kept for all of it.
  public let videoDecoderConfiguration: UmbelVideoDecoderConfiguration
  private let demux: DemuxSession
  private let audioOutput: (any AudioOutput)?
  private let videoRenderer: (any VideoRenderer)?
  private let clock: PresentationClock
  let diagnostics: UmbelPlaybackDiagnostics?
  private let videoObservation: VideoPresentationObservation
  private let requestedVideoPolicy: UmbelVideoPolicy?
  public var videoPresentationStatus: UmbelVideoPresentationStatus { videoObservation.snapshot }
  /// Whether interlaced frames are made progressive; read while decoding.
  let deinterlace = DeinterlaceSwitch()

  /// The sound: which track, and how it plays.
  let audio: AudioPath
  private var videoDecodeSession: (any VideoFrameSource)?
  var audioTrack: UmbelTrack?
  var videoTrack: UmbelTrack?
  let subtitles: SubtitleController
  /// Answers the display loop: frames, and subtitles in or beside them.
  let presenter: PlaybackPresenter
  var isStopped = false
  private var isOpening = false
  /// Why `load()` failed. Failures after loading live in the pipeline.
  private var loadFailure: UmbelError?
  /// Seek generation: up by one each `seek`, compared after each `await`;
  /// see `PresentedFrame.seekGeneration`.
  public private(set) var seekGeneration = 0
  var pictureSignal = PictureSignal()
  /// Where the latest seek goes, until the clock has been set there.
  private var seekTarget: CMTime?
  private var routingRequest = 0
  /// The picture is not decoded; see `setVideoSuspended(_:)`.
  private var isVideoSuspended = false
  private var videoTransition = 0
  private var isVideoTransitioning = false

  private let buffering: BufferingConfiguration
  private let cachedAudio: CachedAudioConfiguration
  /// Moves the data; the session decides what should move. Built by
  /// `load()`, once the audio track the cache measures by is known.
  var pipeline: PlaybackPipeline?
  /// What the pipeline has read ahead of the decoders.
  var cache: PacketCache?
  /// How fast it plays; see `setRate(_:)`.
  public internal(set) var rate = 1.0
  /// How loud, 0...1, and whether muted; see `setVolume(_:)`.
  public internal(set) var volume: Float = 1
  public internal(set) var isMuted = false
  var presentation = PresentationSettings()

  /// Composites subtitles unless the host draws them with `renderSubtitles(in:)`.
  /// Object audio follows `UmbelObjectAudioMode`; diagnostics records observations.
  /// A nil video policy inherits the renderer settings; explicit policies are checked at load.
  public init(
    source: UmbelSource, audioOutput: (any AudioOutput)? = nil,
    videoRenderer: (any VideoRenderer)? = nil, videoPolicy: UmbelVideoPolicy?,
    compositesSubtitles: Bool = true, hostTime: HostTimeSource = SystemHostTimeSource(),
    configuration: DemuxConfiguration = .init(), buffering: BufferingConfiguration = .init(),
    cachedAudio: CachedAudioConfiguration = .init(),
    videoDecodingMode: UmbelVideoDecodingMode = .synchronous, videoDecoder: UmbelVideoDecoderConfiguration = .init(),
    objectAudio: UmbelObjectAudioMode = .automatic, diagnostics: UmbelPlaybackDiagnostics? = nil
  ) {
    self.requestedVideoPolicy = videoPolicy
    self.demux = DemuxSession(source: source, configuration: configuration, diagnostics: diagnostics)
    self.diagnostics = diagnostics
    self.videoObservation = VideoPresentationObservation(diagnostics: diagnostics)
    self.audio = AudioPath(demux: demux, output: audioOutput, mode: objectAudio)
    self.subtitles = SubtitleController(demux: demux)
    self.audioOutput = audioOutput
    self.videoRenderer = videoRenderer
    self.clock = SystemTimelineWiring.clock(
      hostTime: hostTime, audioOutput: audioOutput, videoRenderer: videoRenderer, diagnostics: diagnostics)
    self.buffering = buffering
    self.cachedAudio = cachedAudio
    self.videoDecodingMode = videoDecodingMode
    self.videoDecoderConfiguration = videoDecoder
    self.presenter = PlaybackPresenter(
      renderer: videoRenderer, clock: clock, subtitles: subtitles,
      compositesSubtitles: compositesSubtitles)
  }

  /// The selected route; temporary suspension does not change this status.
  public var videoDecodingStatus: UmbelVideoDecodingStatus {
    guard pipeline != nil, !isStopped, !isOpening, loadFailure == nil,
          videoDecodeSession != nil else { return .inactive }
    if videoObservation.snapshot.route?.isSystem == true { return .systemManaged }
    return videoDecodingMode == .asynchronous ? .asynchronous : .synchronous
  }

  /// What decodes the chosen video track now: what happens, not what was asked.
  public var videoDecoderStatus: UmbelVideoDecoderStatus {
    get async {
      switch videoDecodingStatus {
      case .inactive: return .inactive
      case .systemManaged: return .systemManaged
      case .synchronous, .asynchronous: return await videoDecodeSession?.decoderStatus ?? .inactive
      }
    }
  }

  func recoverVideoOutputFailure(_ error: Error) async throws -> Bool {
    guard let path = videoDecodeSession as? VideoPath else { return false }
    return try await path.recoverDisplayFailure(error)
  }

  /// What the decoders here have done with the chosen tracks' packets.
  public var decodingStatistics: UmbelDecodingStatistics {
    get async { .init(video: await videoDecodeSession?.decodingCounts, audio: await audio.decoder?.decodingCounts) }
  }

  /// The container's tracks, then any external subtitle files added.
  public var tracks: [UmbelTrack] {
    get async { await demux.tracks + subtitles.externalTracks }
  }
  public var duration: CMTime { get async { await demux.duration } }
  /// Where playback stands; while a seek is under way, where it goes.
  public var currentTime: CMTime {
    get async {
      if let seekTarget { return seekTarget }
      return await clock.now()
    }
  }
  public var clockAuthority: PresentationClock.Authority {
    get async { await clock.authority }
  }

  /// Whether `seek(to:)` can move in the content: false before `load()`,
  /// after `stop()`, and for a stream read only in order or a live one.
  public var isSeekable: Bool {
    get async {
      guard pipeline != nil, !isStopped else { return false }
      return await demux.isSeekable
    }
  }

  /// Why playback failed, once `phase` is `.failed`. Nil otherwise.
  public var failureReason: UmbelError? {
    get async {
      if let loadFailure { return loadFailure }
      return await pipeline?.failureReason
    }
  }

  /// The current phase, derived from session intent and pipeline state.
  public var phase: UmbelPlaybackPhase {
    get async {
      if isStopped { return .idle }
      if loadFailure != nil { return .failed }
      if isOpening { return .opening }
      guard let pipeline else { return .idle }
      if let terminal = await pipeline.terminal { return terminal }
      // Paused is paused, however little is buffered. Waiting only exists as
      // a state of wanting to play: paused, waiting to play, or playing.
      guard wantsToPlay else { return .paused }
      if await pipeline.isRebuffering { return .buffering }
      if await audio.isWaitingToPlay { return .buffering }
      return .playing
    }
  }

  /// Playback intent; the pipeline decides when the clock can run.
  private var wantsToPlay = false

  public func load() async throws {
    isOpening = true
    defer { isOpening = false }
    await (audioOutput as? any PlaybackDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics)
    await (videoRenderer as? any VideoDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics, output: "video")
    await (videoRenderer as? any VideoPresentationObserving)?.setVideoPresentationObservation(videoObservation, output: "video")
    diagnostics?.record("session_open", labels: [
      "frameworkVersion": Umbel.version, "requestedDecoding": videoDecodingMode.rawValue,
      "audioOutput": audioOutput.map { String(describing: type(of: $0)) } ?? "none",
      "renderer": videoRenderer.map { String(describing: type(of: $0)) } ?? "none"])
    do {
      try await openAndSelect()
      isOpening = false
      diagnostics?.record("session_loaded", values: [
        "audioTrack": audioTrack.map { Double($0.id.rawValue) } ?? .nan,
        "videoTrack": videoTrack.map { Double($0.id.rawValue) } ?? .nan],
        labels: ["audioRoute": String(describing: await audio.route),
                 "selectedDecoding": String(describing: videoDecodingStatus)])
    } catch {
      loadFailure = UmbelError.wrapping(error)
      throw error
    }
  }

  private func openAndSelect() async throws {
    try await demux.open()
    let tracks = await demux.tracks
    await audio.connect(
      soundReady: { [weak self] in await self?.pipeline?.setSoundReady($0) },
      rerouted: { [weak self] in await self?.rerouted() })
    await audio.setAudioDelay(presentation.audioDelayTime)

    if audioOutput != nil, let track = TrackPreference.preferred(of: .audio, in: tracks) {
      audioTrack = track
      _ = try await audio.select(track, at: .zero)
      await clock.setAuthority(.audio)
    } else {
      // No sound track (or no output): the clock falls back to the host
      // clock — the same code, with no anchors coming in.
      await clock.setAuthority(.host)
    }

    if let renderer = videoRenderer, let track = tracks.first(where: { $0.kind == .video }) {
      videoTrack = track
      videoDecodeSession = try await VideoRoute.session(
        for: track, demux: demux, renderer: renderer, mode: videoDecodingMode,
        decoder: videoDecoderConfiguration, deinterlacing: deinterlace, diagnostics: diagnostics,
        policy: requestedVideoPolicy, observation: videoObservation, resumeTime: { [clock] in await clock.now() })
      try await renderer.prepare(for: track, plan: videoObservation.selectedPlan)
    }

    // A subtitle that cannot be shown is no reason to refuse the film.
    await subtitles.loadEmbeddedFonts()
    try? await subtitles.followAudio(audioTrack)

    // The pipeline is built after audio selection settles its measured track.
    let built = await PlaybackPipeline.assembled(
      demux: demux, tracks: tracks, audioTrack: audioTrack?.id, audioOutput: audioOutput,
      videoRenderer: videoRenderer, clock: clock, buffering: buffering, cachedAudio: cachedAudio,
      diagnostics: diagnostics)
    (pipeline, cache) = (built.pipeline, built.cache)
    await pipeline?.setRate(rate)
    await pipeline?.setAudioDelay(presentation.audioDelayTime)
    // Held back until the system player's clock leads, if it plays the sound.
    await pipeline?.setSoundReady(await audio.isSoundReady)
    await pushRouting()
    try await SystemTimelineWiring.join(audioOutput, videoRenderer)
  }

  /// Asks to play. The clock starts once enough is buffered; until then the
  /// phase is `.buffering`.
  public func play() async throws {
    guard !isStopped, let pipeline else { return }
    diagnostics?.record("session_play", values: [
      "generation": Double(seekGeneration), "rate": rate])
    wantsToPlay = true
    try await pipeline.setWantsToPlay(true)
    await pipeline.start()
  }

  public func pause() async {
    diagnostics?.record("session_pause", values: [
      "generation": Double(seekGeneration)])
    wantsToPlay = false
    try? await pipeline?.setWantsToPlay(false)
  }

  public func stop() async {
    guard !isStopped else { return }
    isStopped = true
    seekGeneration += 1
    seekTarget = nil
    videoTransition += 1
    await pipeline?.stop()
    await clock.setRate(0)
    await audioOutput?.stop()
    await videoRenderer?.flush()
    await SystemTimelineWiring.leave(videoRenderer)
    await audio.close()
    await videoDecodeSession?.close()
    videoDecodeSession = nil
    videoObservation.reset()
    await subtitles.close()
    await demux.close()
  }

  /// Seeks while retaining rate and paused/playing intent. Only the latest
  /// overlapping request takes effect. Buffered forward seeks and, when
  /// enabled and complete, backward history reuse what was read; see `PlaybackSeek`.
  public func seek(to time: CMTime) async throws {
    try await seek(to: time, usingCache: true)
  }

  /// Coverage recovery must bypass forward reuse too: decoded subtitles can
  /// be missing even when the audio/video queues still cover the target.
  private func seek(to time: CMTime, usingCache: Bool) async throws {
    guard !isStopped else { return }
    // Refused before anything stops: a live stream plays on as it was.
    guard await demux.isSeekable else { throw UmbelError.seekUnsupported }
    seekGeneration &+= 1
    let generation = seekGeneration
    pictureSignal.seekBegan()
    diagnostics?.record("session_seek", values: ["target": time.seconds, "generation": Double(generation)])
    let target = SeekTarget.clamped(time, duration: await demux.duration)
    guard generation == seekGeneration else { return }
    seekTarget = target
    defer { if generation == seekGeneration { seekTarget = nil } }
    try await PlaybackSeek(
      target: target, pipeline: pipeline, cache: cache, audio: audio, subtitles: subtitles, clock: clock,
      audioOutput: audioOutput, videoRenderer: videoRenderer, videoDecodeSession: videoDecodeSession,
      diagnostics: diagnostics, mayKeepCache: usingCache && !isVideoTransitioning,
      isCurrent: { [weak self] in await self?.seekGeneration == generation },
      reroute: { [weak self] in await self?.pushRouting() }
    ).run()
    pictureSignal.seekSettled(generation, latest: seekGeneration)
  }

  /// Switches audio, or silences it with nil, retaining position and picture.
  /// Feeding follows the new route on its next round; a system-audio handover
  /// restarts reading where playback stands.
  public func selectAudioTrack(_ id: UmbelTrack.ID?) async throws {
    try await AudioTrackSwitch(id: id, clock: clock, demux: demux).run(in: self)
  }

  /// Selection and offset changes can expose a subtitle gap left by a cached
  /// rewind. External subtitles have no packet requirements; live inputs keep
  /// their existing forward-only behavior. Retry observations changed mid-await.
  func recoverSubtitleCoverage(since revision: Int) async throws {
    guard let cache, await demux.isSeekable else { return }
    while !isStopped {
      let generation = seekGeneration
      let now = await currentTime
      let snapshot = await subtitles.replaySnapshot(at: now, changedSince: revision)
      guard snapshot.revision != revision else { return }
      let complete = await cache.canReplaySubtitles(snapshot.requirements)
      guard await subtitles.isCurrent(snapshot), generation == seekGeneration else { continue }
      if !complete { try await seek(to: now, usingCache: false) }
      return
    }
  }

  /// Suspends picture decoding while sound continues. Resuming renews the
  /// decoder and seeks to the current clock, or waits for a keyframe on a
  /// source that cannot seek. The selected decoding status stays unchanged.
  public func setVideoSuspended(_ suspended: Bool) async {
    guard suspended != isVideoSuspended, !isStopped, videoTrack != nil else { return }
    isVideoSuspended = suspended
    isVideoTransitioning = true
    videoTransition += 1
    let request = videoTransition
    // Remove the route before cancelling pending async decoding.
    await pushRouting()
    guard request == videoTransition, !isStopped else { return }
    await pipeline?.suspendVideoFeeding()
    guard request == videoTransition, !isStopped else { return }
    await videoDecodeSession?.flush()
    guard request == videoTransition, !isStopped else { return }
    if !suspended {
      do { try await videoDecodeSession?.renew() }
      catch {
        if request == videoTransition, !isStopped { await pipeline?.markFailed(error) }
        return
      }
    }
    guard request == videoTransition, !isStopped else { return }
    isVideoTransitioning = false
    await pushRouting()
    guard !suspended, request == videoTransition, !isStopped else { return }
    let seekable = await demux.isSeekable
    guard request == videoTransition, !isStopped else { return }
    if seekable { try? await seek(to: await currentTime) }
    else { await pipeline?.resumeVideoFeeding() }
  }

  /// The sound changed its way on its own — the system player gave it back
  /// — and is read again from where playback stands.
  private func rerouted() async {
    guard !isStopped else { return }
    await pushRouting()
    try? await seek(to: await currentTime)
  }

  /// Updates the clock from the output's latest anchor.
  public func refreshClock() async {
    guard let anchor = await audioOutput?.currentAnchor else { return }
    await clock.adopt(anchor)
  }

  /// Push the current route, discarding requests superseded across the subtitle actor await.
  func pushRouting() async {
    routingRequest += 1
    let request = routingRequest
    let subtitleRoutes = await subtitles.embeddedSelections
    let sound = await audio.destinations
    guard request == routingRequest else { return }
    await pipeline?.updateRouting(
      PacketRouting(
        audioID: audioTrack?.id,
        audioSession: sound.decoder, objectAudio: sound.objectAudio,
        videoID: isVideoSuspended || isVideoTransitioning ? nil : videoTrack?.id,
        videoSession: videoDecodeSession,
        generation: seekGeneration, subtitleRoutes: subtitleRoutes
      )
    )
  }
}
