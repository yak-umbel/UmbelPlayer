import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// A session's sound: the track chosen and how it plays — decoded here for
/// the audio output, or by the system player when it is E-AC-3 with object
/// coding (`ObjectAudioRoute`) — and falling back from the one to the other.
///
/// The system player's clock leads the session's once its item is ready:
/// the output's timeline is handed over to it, and the session is held back
/// until then (`onSoundReady`). When that player fails, the track is
/// decoded here again, from where playback stands (`onRerouted`), and for
/// the rest of the session: a way that failed once is not tried again.
internal actor AudioPath {
  /// How far before the sound's first segment the demuxer is placed: that
  /// segment's first packets can lie before the key frame it lands on.
  static let demuxLead = CMTime(value: 1, timescale: 2)

  private let demux: DemuxSession
  private let output: (any AudioOutput)?
  /// The output's timeline, when the system player's clock can stand in.
  private let switchable: SwitchableTimeline?
  private let mode: UmbelObjectAudioMode
  private(set) var track: UmbelTrack?
  private(set) var decoder: AudioDecodeSession?
  private(set) var objectAudio: ObjectAudioRoute?
  private(set) var route: UmbelAudioRoute = .none
  /// False from choosing the system player until its clock leads.
  private(set) var isSoundReady = true
  private var routeKey = UUID()
  private var fallback: UmbelObjectAudioFallback?
  private var handover: Task<Void, Never>?
  private var level: (volume: Float, muted: Bool) = (1, false)
  private var delay = CMTime.zero
  private var onSoundReady: @Sendable (Bool) async -> Void = { _ in }
  private var onRerouted: @Sendable () async -> Void = {}
  private var suits: @Sendable (UmbelTrack, FFmpegCodecParameters?, CMTime) -> Bool = ObjectAudioRoute.suits
  private var server: any LoopbackServing = LoopbackServer.shared

  init(demux: DemuxSession, output: (any AudioOutput)?, mode: UmbelObjectAudioMode) {
    self.demux = demux
    self.output = output
    self.switchable = (output as? any SystemTimelineKeeping)?.timeline as? SwitchableTimeline
    self.mode = mode
  }

  /// Where the session hears that it may run, and that the sound changed
  /// its way on its own and reading must start again.
  func connect(
    soundReady: @escaping @Sendable (Bool) async -> Void, rerouted: @escaping @Sendable () async -> Void
  ) {
    onSoundReady = soundReady
    onRerouted = rerouted
  }

  /// Which tracks go to the system player, and what serves it. Tests widen
  /// the first to E-AC-3 without objects, which is all an encoder here can
  /// write, and stand in for the second.
  func routeToSystemPlayer(
    when suits: @escaping @Sendable (UmbelTrack, FFmpegCodecParameters?, CMTime) -> Bool,
    servedBy server: any LoopbackServing = LoopbackServer.shared
  ) {
    self.suits = suits
    self.server = server
  }

  /// Where packets go: one of the two, or neither.
  var destinations: (decoder: AudioDecodeSession?, objectAudio: ObjectAudioRoute?) { (decoder, objectAudio) }

  /// Chooses `track`, nil for none, and how it plays from `position`. The
  /// new way is made before the old is taken down, so a failure leaves the
  /// old. True when the system player took the sound or gave it back:
  /// reading must then start again where playback stands.
  func select(_ track: UmbelTrack?, at position: CMTime) async throws -> Bool {
    let wasSystem = objectAudio != nil
    guard let track else {
      await dropCurrent()
      self.track = nil
      route = .none
      await output?.flush()
      return wasSystem
    }
    if let (made, key) = await systemRoute(for: track, at: position) {
      // Prepared as well: it plays the sound again should the player fail.
      try await output?.prepare(for: track)
      await dropCurrent()
      self.track = track
      objectAudio = made
      routeKey = key
      route = .systemPlayer
      await handOverWhenReady(made)
      return true
    }
    let made = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: track.id))
    await dropCurrent()
    self.track = track
    decoder = made
    route = await engineRoute(for: track)
    if let output {
      // The new track's format may differ: reconfigure; flush drops the old.
      try await output.prepare(for: track)
      await output.flush()
    }
    return wasSystem
  }

  /// Chooses the audio track `id`; throws `trackUnavailable` for none such.
  func select(trackWithID id: UmbelTrack.ID, at position: CMTime) async throws -> (UmbelTrack, Bool) {
    guard let track = await demux.tracks.first(where: { $0.id == id }), track.kind == .audio else {
      throw UmbelError.trackUnavailable("no audio track \(id.rawValue)")
    }
    return (track, try await select(track, at: position))
  }

  /// Where reading must begin for a seek to `target`, when the system
  /// player wants whole segments from before it.
  func readingStart(forSeekTo target: CMTime) -> CMTime? {
    objectAudio?.readingStart(forSeekTo: target)
  }

  /// `keeping`: the seek goes on with what is read; see `ObjectAudioRoute.keepReading`.
  func prepareSeek(to target: CMTime, keeping: Bool = false) async {
    await decoder?.flush()
    await objectAudio?.prepareSeek(to: target, keeping: keeping)
  }

  func setLevel(volume: Float, muted: Bool) async {
    level = (volume, muted)
    await output?.setVolume(volume, muted: muted)
    await objectAudio?.setLevel(volume: volume, muted: muted)
  }

  /// With the system player on the sound, the pictures move instead.
  func setAudioDelay(_ delay: CMTime) async {
    self.delay = delay
    await objectAudio?.setAudioDelay(delay)
  }

  /// The system player means to play and is waiting: buffering.
  var isWaitingToPlay: Bool {
    get async { await objectAudio?.isWaitingToPlay ?? false }
  }

  func close() async {
    await dropCurrent()
  }

  // ── The system player ───────────────────────────────

  private func systemRoute(for track: UmbelTrack, at position: CMTime) async -> (ObjectAudioRoute, UUID)? {
    guard mode == .automatic, fallback == nil, switchable != nil else { return nil }
    let parameters = await demux.codecParameters(for: track.id)
    let duration = await demux.duration
    guard let parameters, suits(track, parameters, duration) else { return nil }
    let key = UUID()
    let made = ObjectAudioRoute(
      track: track, parameters: parameters, duration: duration, server: server,
      onFailure: { [weak self] reason in await self?.fallBack(reason, from: key) })
    do {
      try await made.start(at: position)
    } catch {
      await made.close()
      fallback = error as? UmbelObjectAudioFallback ?? .serverUnavailable(error.localizedDescription)
      return nil
    }
    await made.setLevel(volume: level.volume, muted: level.muted)
    await made.setAudioDelay(delay)
    return (made, key)
  }

  /// Decoded here: after a fallback, a track that would have gone to the
  /// system player says why it did not.
  private func engineRoute(for track: UmbelTrack) async -> UmbelAudioRoute {
    guard let fallback, mode == .automatic, switchable != nil else { return .engine }
    let parameters = await demux.codecParameters(for: track.id)
    return suits(track, parameters, await demux.duration) ? .engineAfterFallback(fallback) : .engine
  }

  /// Holds the session back until the player's clock leads.
  private func handOverWhenReady(_ route: ObjectAudioRoute) async {
    isSoundReady = false
    await onSoundReady(false)
    handover = Task { [weak self] in
      guard let timeline = await route.takeLead() else { return }
      await self?.lead(with: timeline, of: route)
    }
  }

  private func lead(with timeline: PlayerItemTimeline, of route: ObjectAudioRoute) async {
    guard route === objectAudio, let switchable else { return }
    await switchable.hand(over: timeline)
    guard route === objectAudio, !isSoundReady else { return }
    isSoundReady = true
    await onSoundReady(true)
  }

  private func fallBack(_ reason: UmbelObjectAudioFallback, from key: UUID) async {
    guard key == routeKey, objectAudio != nil, let track else { return }
    fallback = reason
    let made = try? await demux.makeAudioDecoder(for: track.id)
    guard key == routeKey, objectAudio != nil else { return }
    await dropCurrent()
    decoder = made.map { AudioDecodeSession(decoder: $0) }
    route = decoder == nil ? .none : .engineAfterFallback(reason)
    await onRerouted()
  }

  /// Takes down the way the current track plays; the synchronizer leads
  /// again from where the player stood.
  private func dropCurrent() async {
    handover?.cancel()
    handover = nil
    routeKey = UUID()
    if let route = objectAudio {
      objectAudio = nil
      await switchable?.takeBack()
      await route.close()
    }
    await decoder?.close()
    decoder = nil
    if !isSoundReady {
      isSoundReady = true
      await onSoundReady(true)
    }
  }
}
