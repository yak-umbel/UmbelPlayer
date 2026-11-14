import AVFoundation
import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Where segments are served from; `LoopbackServer`, or a stand-in in tests.
internal protocol LoopbackServing: Sendable {
  func register(_ handler: @escaping LoopbackServer.Handler) async throws -> URL
  func unregister(_ base: URL) async
}

extension LoopbackServer: LoopbackServing {}

/// A sound track the system player plays instead of the engine decoding
/// it, so that the system renders what the engine cannot: the objects of
/// E-AC-3 with joint object coding.
///
/// Reading hands the track's packets over (`take(_:)`) and reads nothing
/// twice. They are made into fragmented MP4 segments when asked for, and
/// served on loopback to a player that plays this sound alone. Its clock,
/// `timeline`, leads the session once ready, and the pictures follow it.
///
/// The route watches that player, and tells the segments where it plays:
/// played again from what it kept, it asks for nothing. Failing, or given
/// everything it asked for and still not playing after five seconds, it is
/// reported once (`onFailure`), and the session decodes the track itself
/// again. Waiting on reading is buffering, however long.
internal actor ObjectAudioRoute {
  /// FFmpeg's profile number for E-AC-3 with joint object coding.
  static let objectCodingProfile: Int32 = 30
  /// 2.016 s at 48 kHz: a seek reads from the segment before its target's,
  /// at most about four seconds early, and the first segment is soon ready.
  static let framesPerSegment = 63
  /// Samples in an E-AC-3 frame of six blocks.
  static let samplesPerFrame = 1536

  private let parameters: FFmpegCodecParameters
  private let plan: SegmentPlan
  private var playlist = Data()
  private let store: SegmentStore
  private let server: any LoopbackServing
  private let onFailure: @Sendable (UmbelObjectAudioFallback) async -> Void
  private var base: URL?
  private var player: PlayerItemTimeline?
  /// Its clock leads the session: seeks move it, rather than replace it.
  private var isLeading = false
  private var level: (volume: Float, muted: Bool) = (1, false)
  private var delay = CMTime.zero
  private var fragments: FragmentedAudioTrack?
  private var watch: Task<Void, Never>?
  private var reported = false
  private var closed = false

  /// Whether `track` should go this way: E-AC-3 with object coding, in
  /// content of a known length, since the playlist is written whole first.
  static func suits(_ track: UmbelTrack, parameters: FFmpegCodecParameters?, duration: CMTime) -> Bool {
    guard track.kind == .audio, track.codecName == "eac3", parameters?.profile == objectCodingProfile,
          let rate = track.audio?.sampleRate, rate > 0 else { return false }
    return duration.isNumeric && duration > .zero
  }

  init(
    track: UmbelTrack, parameters: FFmpegCodecParameters, duration: CMTime,
    server: any LoopbackServing = LoopbackServer.shared,
    onFailure: @escaping @Sendable (UmbelObjectAudioFallback) async -> Void
  ) {
    let frame = CMTime(
      value: CMTimeValue(Self.samplesPerFrame), timescale: CMTimeScale(track.audio?.sampleRate ?? 48_000))
    // Encoders start sound a little before 0 (E-AC-3: 256 samples), and a
    // fragment's time cannot be negative: a frame later on the player's
    // clock covers it.
    let plan = SegmentPlan(
      frameDuration: frame, framesPerSegment: Self.framesPerSegment, duration: duration, shift: frame)
    self.parameters = parameters
    self.plan = plan
    self.store = SegmentStore(plan: plan)
    self.server = server
    self.onFailure = onFailure
  }

  /// The system player's clock now; nil until started. Replaced by a seek
  /// until it leads; see `takeLead()`.
  var timeline: PlayerItemTimeline? { player }

  /// Serves the track and makes its player, to play from `position` in the
  /// film. Throws `serverUnavailable` when the loopback server cannot listen.
  func start(at position: CMTime = .zero) async throws {
    let base: URL
    do {
      base = try await server.register { [weak self] name in try await self?.resource(named: name) }
    } catch {
      throw UmbelObjectAudioFallback.serverUnavailable(error.localizedDescription)
    }
    self.base = base
    await replacePlayer(startingAt: position)
    watch = Task { [weak self] in await self?.watchPlayer() }
  }

  func setLevel(volume: Float, muted: Bool) {
    level = (volume, muted)
    player?.setLevel(volume: volume, muted: muted)
  }

  func setAudioDelay(_ delay: CMTime) {
    self.delay = delay
    player?.setAudioDelay(delay)
  }

  // ── Reading's part ──────────────────────────────────

  /// Takes a packet of the track; waits while reading is far ahead of the
  /// player. Once closed it drops them: feeding may still hold the route
  /// that fell back or was switched away from, and is told so next round.
  func take(_ packet: DemuxPacket) async throws {
    do {
      try await store.append(packet)
    } catch SegmentStore.Failure.closed {
      return
    }
  }

  func finishReading() async {
    await store.finish()
  }

  /// Where reading must begin, for a seek to `target`, to bring the
  /// segments the player will want. It asks for earlier ones too, and goes
  /// on without them when told there are none.
  nonisolated func readingStart(forSeekTo target: CMTime) -> CMTime {
    plan.start(of: plan.firstSegment(forSeekTo: target))
  }

  /// Whether a seek to `target` can go on with the sound read already, the
  /// packet reading brings next starting at `next`: the player is moved
  /// alone (`prepareSeek(to:keeping:)`), and the segments it asks for first
  /// are held, or still to come in order; see `SegmentStore.keep`. Only a
  /// player that leads is moved. If so, the segment is kept until it is
  /// there; a seek that then reads again resets the store.
  func keepReading(forSeekTo target: CMTime, nextPacketAt next: CMTime?) async -> Bool {
    guard !closed, isLeading else { return false }
    return await store.keep(from: plan.firstSegment(forSeekTo: target), nextPacketAt: next)
  }

  /// Makes ready for reading to start again for a seek to `target`: the
  /// player goes there first — moved when it leads, replaced by one that
  /// starts there before — and only then are the segments it had asked for
  /// forgotten. Told there are none while still wanting them, it fails.
  /// Going on with what is read (`keepReading`), none are forgotten: the
  /// player asks for what is held, and reading goes on where it was.
  func prepareSeek(to target: CMTime, keeping: Bool = false) async {
    guard !closed else { return }
    if isLeading, let player {
      player.set(rate: player.requestedRate, time: target)
      // Its controls run on the main queue: the seek is under way after this.
      await MainActor.run {}
    } else {
      await replacePlayer(startingAt: target)
    }
    if keeping {
      await store.playerWasMoved()
    } else {
      await store.reset(to: plan.firstSegment(forSeekTo: target))
    }
  }

  // ── The player ──────────────────────────────────────

  /// Waits for the player's item to be ready, then lets its clock lead:
  /// from here on seeks move it. Nil once closed.
  func takeLead() async -> PlayerItemTimeline? {
    while !closed, !Task.isCancelled, let player {
      let look = await Self.look(at: player)
      // Replaced while looked at: look at the new one.
      if look.isReady, player === self.player {
        isLeading = true
        return player
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return nil
  }

  /// Reading has stopped at the packet byte budget with none of this sound
  /// to hand over: whether that leaves the player stuck. Only waiting on
  /// reading does — getting ready, or leading and meant to play but not
  /// playing. Otherwise it keeps its route — playing, paused on purpose, or
  /// getting ready with all it asked for — and the watch sees to one that
  /// never gets on.
  var isStuckAtPacketLimit: Bool {
    get async {
      guard !closed, let player else { return false }
      let look = await Self.look(at: player)
      let waitingOnReading = await store.isWaiting
      guard !closed, player === self.player, waitingOnReading else { return false }
      return !look.isReady || (isLeading && look.shouldPlay && !look.isPlaying && !look.isAtEnd)
    }
  }

  /// Stuck so, gives the sound back. `stillWanted` is asked last, after
  /// looking: a seek meanwhile makes the request stale. Returns whether it
  /// reported.
  @discardableResult
  func fallBackAtPacketLimit(stillWanted: @Sendable () async -> Bool) async -> Bool {
    let looked = player
    guard await isStuckAtPacketLimit, await stillWanted(), !closed, player === looked else { return false }
    await report(.notPlaying)
    return true
  }

  /// Closed: it takes nothing and reports nothing any more.
  var isClosed: Bool { closed }

  /// Meant to play, and not: buffering, from where the session stands.
  var isWaitingToPlay: Bool {
    get async {
      guard !closed, let player else { return false }
      let look = await Self.look(at: player)
      return look.shouldPlay && !look.isPlaying && !look.isAtEnd
    }
  }

  func close() async {
    guard !closed else { return }
    closed = true
    watch?.cancel()
    await store.close()
    player?.close()
    if let base { await server.unregister(base) }
  }

  /// A new player, its playlist saying where to start: one made to load
  /// elsewhere asks for segments reading will not bring. The old one's
  /// requests end as it goes.
  private func replacePlayer(startingAt position: CMTime) async {
    player?.close()
    await store.reset(to: plan.firstSegment(forSeekTo: position))
    playlist = Data(plan.playlist(initName: "init.mp4", segmentName: { "seg\($0).m4s" }, start: position).utf8)
    guard let base else { return }
    let made = PlayerItemTimeline(url: base.appendingPathComponent("index.m3u8"), shift: plan.shift)
    made.setLevel(volume: level.volume, muted: level.muted)
    made.setAudioDelay(delay)
    player = made
  }

  private func watchPlayer() async {
    var stall = StallWatch()
    var last: CMTime?
    while !Task.isCancelled, !closed, let player {
      // Taken before looking: a seek meanwhile makes what is seen stale.
      let epoch = await store.epoch
      let look = await Self.look(at: player)
      if let failure = look.failure { return await report(.playerFailed(failure)) }
      if look.isReady, !look.isSeeking {
        await store.playerIsAt(CMTimeSubtract(look.time, plan.shift), epoch: epoch)
      }
      let waitingOnReading = await store.isWaiting
      // It can say it plays while its clock stands still.
      let moving = look.isPlaying && last.map { abs((look.time - $0).seconds) > 0.01 } == true
      last = look.time
      // Until it leads, getting ready is what it should be doing.
      let expected = isLeading ? look.shouldPlay && !look.isAtEnd : true
      let progressing = isLeading ? moving : look.isReady
      if stall.look(
        shouldPlay: expected, isPlaying: progressing,
        waitingOnReading: waitingOnReading, at: ProcessInfo.processInfo.systemUptime) {
        return await report(.notPlaying)
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
  }

  private func report(_ reason: UmbelObjectAudioFallback) async {
    guard !reported, !closed else { return }
    reported = true
    await onFailure(reason)
  }

  // ── Serving ─────────────────────────────────────────

  private func resource(named name: String) async throws -> LoopbackServer.Resource? {
    switch name {
    case "index.m3u8":
      return .init(data: playlist, contentType: "application/vnd.apple.mpegurl")
    case "init.mp4":
      return .init(data: try await fragmentedTrack().initSegment, contentType: "video/mp4")
    default:
      guard name.hasPrefix("seg"), name.hasSuffix(".m4s"),
            let index = Int(name.dropFirst(3).dropLast(4)), (0..<plan.count).contains(index) else { return nil }
      let packets: [DemuxPacket]
      do {
        packets = try await store.packets(of: index)
      } catch SegmentStore.Failure.gone {
        return nil
      }
      // Listed but past the sound's end. Not found, the player plays what
      // there is and says it has played to the end; given an empty
      // fragment, it fails.
      guard !packets.isEmpty else { return nil }
      let fragment = try await fragmentedTrack().fragment(sequence: UInt32(index + 1), packets: packets)
      return .init(data: fragment, contentType: "video/mp4")
    }
  }

  /// Made once, from the track's first packets.
  private func fragmentedTrack() async throws -> FragmentedAudioTrack {
    if let fragments { return fragments }
    let leading = try await store.leading()
    if let fragments { return fragments }
    let made = try FragmentedAudioTrack.make(parameters: parameters, leading: leading, shift: plan.shift)
    fragments = made
    return made
  }

  // ── Looking at the player ───────────────────────────

  private struct Look: Sendable {
    var isReady = false
    var failure: String?
    /// Asked to play.
    var shouldPlay = false
    var isPlaying = false
    var isAtEnd = false
    var time = CMTime.zero
    var isSeeking = false
  }

  /// The player is looked at where it is controlled.
  @MainActor
  private static func look(at timeline: PlayerItemTimeline) -> Look {
    let player = timeline.player
    guard let item = player.currentItem else { return Look() }
    var look = Look()
    if item.status == .failed {
      look.failure = item.error?.localizedDescription ?? "the system player failed the item"
      return look
    }
    look.isReady = item.status == .readyToPlay && item.timebase != nil
    look.shouldPlay = timeline.requestedRate > 0
    look.isPlaying = player.timeControlStatus == .playing
    look.time = item.currentTime()
    look.isSeeking = timeline.isSeeking
    let duration = item.duration
    if duration.isNumeric {
      look.isAtEnd = CMTimeAdd(item.currentTime(), CMTime(value: 1, timescale: 4)) >= duration
    }
    // Past the sound's end the player waits for no more: not stuck.
    look.isAtEnd = look.isAtEnd || timeline.isPastSoundEnd
    return look
  }
}
