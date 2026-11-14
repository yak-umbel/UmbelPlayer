import AVFoundation
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private actor MissingVideoPacketSource: VideoFrameSource {
  var skipsNonReference = false
  func decode(_ packet: DemuxPacket, hidden: Bool) async throws -> [VideoFrame] { [] }
  func drain() async throws -> [VideoFrame] { [] }
  func flush() async {}
  func renew() async throws {}
  func close() async {}
  func setSkipsNonReference(_ skips: Bool) async { skipsNonReference = skips }
}

/// Serves what it is given, but garbles every segment: a system player that
/// cannot play what it gets.
private struct GarblingServer: LoopbackServing {
  func register(_ handler: @escaping LoopbackServer.Handler) async throws -> URL {
    try await LoopbackServer.shared.register { name in
      let resource = try await handler(name)
      guard let resource, name.hasPrefix("seg") else { return resource }
      return .init(data: Data(repeating: 0x5A, count: resource.data.count), contentType: resource.contentType)
    }
  }

  func unregister(_ base: URL) async {
    await LoopbackServer.shared.unregister(base)
  }
}

/// A session whose E-AC-3 plays through the system player, the engine's
/// clock following it. The fixture's E-AC-3 has no objects, so the tests
/// send any E-AC-3 that way. Silent; skipped without an audio device.
final class ObjectAudioSessionTests: XCTestCase {
  private func session(
    objectAudio: UmbelObjectAudioMode = .automatic, server: any LoopbackServing = LoopbackServer.shared,
    videoRenderer: (any VideoRenderer)? = nil, buffering: BufferingConfiguration = .init(),
    fixture: String = "eac3_movie.mkv", diagnostics: UmbelPlaybackDiagnostics? = nil
  ) async throws -> PlaybackSession {
    let output = SampleBufferAudioOutput(timeline: SwitchableTimeline(base: SynchronizerTimeline())) {
      SystemAudioRenderer(volume: 0, onDiscarded: $0)
    }
    let session = PlaybackSession(
      source: try UmbelFileSource(url: ServedEAC3.fixture(fixture)),
      audioOutput: output, videoRenderer: videoRenderer, buffering: buffering, objectAudio: objectAudio,
      diagnostics: diagnostics)
    await session.audio.routeToSystemPlayer(when: { track, _, _ in track.codecName == "eac3" }, servedBy: server)
    await session.setVolume(0)
    addTeardownBlock { await session.stop() }
    try await session.load()
    return session
  }

  /// Plays and waits for the clock to move, or skips where it never does.
  private func play(_ session: PlaybackSession) async throws {
    try await session.play()
    for _ in 0..<500 where await session.currentTime.seconds <= 0.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard await session.currentTime.seconds > 0.05 else { throw XCTSkip("no audio output device here") }
  }

  private func advance(of session: PlaybackSession, over seconds: Double) async throws -> Double {
    // How far it went for each `seconds` of real time: a sleep returns late on a busy machine.
    let before = await session.currentTime.seconds
    let started = ContinuousClock.now
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let moved = await session.currentTime.seconds - before
    let elapsed = (ContinuousClock.now - started).inSeconds
    return moved * seconds / elapsed
  }

  func testReadySystemSoundCanStartBeforeAMissingPictureAtThePacketLimit() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let session = try await session(
      videoRenderer: renderer,
      buffering: .init(startThreshold: 60, target: 100, maximumPacketBytes: 1))
    let found = await session.pipeline
    let pipeline = try XCTUnwrap(found)
    let sound = await session.audio.destinations
    await pipeline.updateRouting(PacketRouting(
      audioID: await session.selectedAudioTrack, audioSession: sound.decoder,
      objectAudio: sound.objectAudio, videoID: .init(rawValue: 99),
      videoSession: MissingVideoPacketSource(), generation: 0))
    try await session.play()
    for _ in 0..<500 {
      if await session.audio.isSoundReady { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    for _ in 0..<100 {
      if await pipeline.isRunning { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let ready = await session.audio.isSoundReady
    XCTAssertTrue(ready, "the system sound has its own ready timeline")
    let running = await pipeline.isRunning
    XCTAssertTrue(running, "available sound must not wait forever for video beyond the byte limit")
    let route = await session.audioRoute
    XCTAssertEqual(route, .systemPlayer)
  }

  func testPacketLimitFallsBackWhenStartupCannotReachTheRequestedSound() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let session = try await session(
      videoRenderer: renderer,
      buffering: .init(startThreshold: 60, target: 100, maximumPacketBytes: 1))
    let initial = await session.audioRoute
    XCTAssertEqual(initial, .systemPlayer)
    try await session.play()
    for _ in 0..<500 {
      if await session.audioRoute == .engineAfterFallback(.notPlaying) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let route = await session.audioRoute
    XCTAssertEqual(route, .engineAfterFallback(.notPlaying))
    let ready = await session.audio.isSoundReady
    XCTAssertTrue(ready, "the engine owns the audio clock again after a bounded fallback")
  }

  func testTheSystemPlayerPlaysTheSoundAndLeadsTheClock() async throws {
    let session = try await session()
    let route = await session.audioRoute
    XCTAssertEqual(route, .systemPlayer)
    try await play(session)
    let moved = try await advance(of: session, over: 1)
    XCTAssertEqual(moved, 1, accuracy: 0.1)
    let phase = await session.phase
    XCTAssertEqual(phase, .playing)
    let timeline = await session.audio.objectAudio?.timeline
    let player = try XCTUnwrap(timeline)
    let now = await session.currentTime.seconds
    XCTAssertEqual(now, player.time.seconds, accuracy: 0.05, "the session's time is the player's")
  }

  /// Sound off: the synchronizer keeps time again, from where the player
  /// stood. Back on: the system player again, from where playback stands.
  func testSoundOffAndOnAgainGoesBackToTheSystemPlayer() async throws {
    let session = try await session()
    try await play(session)
    let track = await session.selectedAudioTrack
    try await session.selectAudioTrack(nil)
    var route = await session.audioRoute
    XCTAssertEqual(route, .none)
    let silent = try await advance(of: session, over: 0.5)
    XCTAssertEqual(silent, 0.5, accuracy: 0.15, "the picture's clock runs on")
    let before = await session.currentTime.seconds
    try await session.selectAudioTrack(track)
    route = await session.audioRoute
    XCTAssertEqual(route, .systemPlayer)
    for _ in 0..<300 where await session.currentTime.seconds < before + 0.3 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.15, "played on")
    let now = await session.currentTime.seconds
    XCTAssertEqual(now, before + 1.1, accuracy: 0.8, "from where it stood, not the start")
  }

  func testOffDecodesEverythingHere() async throws {
    let session = try await session(objectAudio: .off)
    let route = await session.audioRoute
    XCTAssertEqual(route, .engine)
    let objectAudio = await session.audio.objectAudio
    XCTAssertNil(objectAudio)
  }

  func testASeekPlaysOnFromTheTarget() async throws {
    let session = try await session()
    try await play(session)
    try await session.seek(to: CMTime(seconds: 7, preferredTimescale: 600))
    for _ in 0..<300 where await session.currentTime.seconds < 7.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let landed = await session.currentTime.seconds
    XCTAssertEqual(landed, 7.1, accuracy: 0.25)
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1)
  }

  /// A session with a picture too: the picture's packets wait in the cache for
  /// the renderer, which is what a seek forward keeps. The long fixture and a
  /// twenty second cache: reading runs ahead of what the system player has
  /// asked for, and sound waits in the cache as it does in a film.
  private func sessionWithPicture(
    diagnostics: UmbelPlaybackDiagnostics? = nil, fixture: String = "eac3_long_movie.mkv"
  ) async throws -> PlaybackSession {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    return try await session(
      videoRenderer: renderer, buffering: .init(target: 20), fixture: fixture, diagnostics: diagnostics)
  }

  /// Playing, with the cache full: what a seek has to go on with.
  private func playWithCache(_ session: PlaybackSession) async throws {
    try await play(session)
    for _ in 0..<500 where await session.bufferedDuration.seconds < 15 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// What a seek since `mark` did: the path it took, and the demuxer's moves.
  private func seekEvents(
    _ diagnostics: UmbelPlaybackDiagnostics, after mark: UInt64
  ) -> (paths: [String], demuxSeeks: Int) {
    let events = diagnostics.snapshot(after: mark).events
    return (events.filter { $0.name == "session_seek_path" }.compactMap { $0.labels["path"] },
            events.filter { $0.name == "demux_seek" }.count)
  }

  /// The system player is moved alone: a seek forward into what is read goes
  /// on with it, the segments it asks for next held or still to come in the
  /// cache, and nothing is read again.
  func testASeekIntoWhatIsReadKeepsItForTheSystemPlayer() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = try await sessionWithPicture(diagnostics: diagnostics)
    try await playWithCache(session)
    let now = await session.currentTime.seconds
    let mark = diagnostics.snapshot().latestSequence
    try await session.seek(to: CMTime(seconds: now + 8, preferredTimescale: 600))
    let seek = seekEvents(diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["cache"])
    XCTAssertEqual(seek.demuxSeeks, 0, "the demuxer stays where it is")
    for _ in 0..<300 where await session.currentTime.seconds < now + 8.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1, "and plays on from there")
    let route = await session.audioRoute
    XCTAssertEqual(route, .systemPlayer, "the sound stays with the system player")
    var shown: [PresentedFrame] = []
    for _ in 0..<50 {
      if let frame = try await session.renderVideoFrame() { shown.append(frame) }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let last = try XCTUnwrap(shown.last)
    let at = await session.currentTime.seconds
    XCTAssertEqual(last.presentationTime.seconds, at, accuracy: 0.25, "the picture goes with the sound")
    XCTAssertGreaterThan(shown.count, 5, "the picture moves")
  }

  /// Each of two seeks in a row goes on with what the one before left.
  func testTwoSeeksForwardInARowBothKeepItForTheSystemPlayer() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = try await sessionWithPicture(diagnostics: diagnostics)
    try await playWithCache(session)
    let now = await session.currentTime.seconds
    let mark = diagnostics.snapshot().latestSequence
    try await session.seek(to: CMTime(seconds: now + 6, preferredTimescale: 600))
    try await session.seek(to: CMTime(seconds: now + 12, preferredTimescale: 600))
    let seek = seekEvents(diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["cache", "cache"])
    XCTAssertEqual(seek.demuxSeeks, 0)
    for _ in 0..<300 where await session.currentTime.seconds < now + 12.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1, "and plays on from there")
  }

  /// Back over what was played, the system player's segments are not in the
  /// cache to go on with: reading starts again, as it does for a seek
  /// forward past what is read.
  func testASeekBackReadsAgainForTheSystemPlayer() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = try await sessionWithPicture(diagnostics: diagnostics)
    try await playWithCache(session)
    try await session.seek(to: CMTime(seconds: 8, preferredTimescale: 600))
    try await Task.sleep(nanoseconds: 500_000_000)
    let mark = diagnostics.snapshot().latestSequence
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    let seek = seekEvents(diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["reread"])
    XCTAssertEqual(seek.demuxSeeks, 1)
    for _ in 0..<300 where await session.currentTime.seconds < 1.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1, "and plays on from there")
  }

  /// A short hop forward, after the player has asked for the rest and let go
  /// of what is behind: the segment it would ask for first is gone, and
  /// reading will not come back for it.
  func testAHopWhoseSegmentsWereLetGoReadsAgainForTheSystemPlayer() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = try await sessionWithPicture(diagnostics: diagnostics)
    try await playWithCache(session)
    for _ in 0..<700 where await session.currentTime.seconds < 5.2 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let now = await session.currentTime.seconds
    let mark = diagnostics.snapshot().latestSequence
    try await session.seek(to: CMTime(seconds: now + 0.5, preferredTimescale: 600))
    let seek = seekEvents(diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["reread"])
    for _ in 0..<300 where await session.currentTime.seconds < now + 0.55 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1, "and plays on from there")
  }

  /// All the sound is in the system player's store and none is left in the
  /// cache. The packet the feeder last took is handed over again, so a seek
  /// still goes on, and the pipeline still learns where the sound ends.
  func testASeekWithAllTheSoundHandedOverStillKeepsItForTheSystemPlayer() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = try await sessionWithPicture(diagnostics: diagnostics, fixture: "eac3_movie.mkv")
    try await play(session)
    for _ in 0..<300 where await session.bufferedDuration.seconds < 10 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let now = await session.currentTime.seconds
    let mark = diagnostics.snapshot().latestSequence
    try await session.seek(to: CMTime(seconds: now + 6, preferredTimescale: 600))
    let seek = seekEvents(diagnostics, after: mark)
    XCTAssertEqual(seek.paths, ["cache"])
    XCTAssertEqual(seek.demuxSeeks, 0)
    for _ in 0..<300 where await session.currentTime.seconds < now + 6.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1, "and plays on from there")
    for _ in 0..<700 where await session.phase != .ended {
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .ended, "and to the end")
  }

  func testPausedItHolds() async throws {
    let session = try await session()
    try await play(session)
    await session.pause()
    try await Task.sleep(nanoseconds: 300_000_000)
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0, accuracy: 0.01)
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
  }

  func testItPlaysToTheEnd() async throws {
    let session = try await session()
    try await play(session)
    try await session.seek(to: CMTime(seconds: 10.5, preferredTimescale: 600))
    for _ in 0..<500 where await session.phase != .ended {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .ended)
  }

  /// The sound stops two seconds before the picture. Its player stopped
  /// there and the clock with it: the last pictures never came, and
  /// playback never ended.
  func testPlaybackEndsWithThePictureAfterTheSound() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let session = try await session(videoRenderer: renderer, fixture: "eac3_short_sound.mkv")
    try await play(session)
    try await session.seek(to: CMTime(seconds: 9, preferredTimescale: 600))
    var shown: PresentedFrame?
    for _ in 0..<400 where await session.phase != .ended {
      if let frame = try await session.renderVideoFrame() { shown = frame }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .ended)
    let end = await session.currentTime.seconds
    XCTAssertEqual(end, 12, accuracy: 0.15, "where the picture ends")
    XCTAssertGreaterThan(shown?.presentationTime.seconds ?? 0, 11.5, "the last pictures shown")
    let route = await session.audioRoute
    XCTAssertEqual(route, .systemPlayer, "to the end, not given back")
  }

  /// Played through, and back a little: the system player plays it again
  /// from what it kept, asking for nothing. Reading, let through only as it
  /// asked, never got to the end, and the second ending never came.
  func testItEndsAgainAfterGoingBackOverWhatItPlayed() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let session = try await session(videoRenderer: renderer)
    try await play(session)
    try await playToTheEnd(session, renderer: session)
    await session.pause()
    // Two seconds in: more of it left than reading is let ahead of the player.
    try await session.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
    try await Task.sleep(nanoseconds: 5_000_000_000)
    try await session.play()
    try await playToTheEnd(session, renderer: session)
    let phase = await session.phase
    XCTAssertEqual(phase, .ended, "the second time too")
    let end = await session.currentTime.seconds
    XCTAssertEqual(end, 12, accuracy: 0.15)
  }

  /// Draws what is due until the session ends, for at most fourteen seconds.
  private func playToTheEnd(_ session: PlaybackSession, renderer: PlaybackSession) async throws {
    for _ in 0..<700 where await session.phase != .ended {
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  /// The picture decoded here, and shown by the system player's clock.
  func testThePictureFollowsTheSystemPlayersClock() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let session = try await session(videoRenderer: renderer)
    try await play(session)
    try await Task.sleep(nanoseconds: 500_000_000)
    var shown: PresentedFrame?
    for _ in 0..<50 {
      if let frame = try await session.renderVideoFrame() { shown = frame }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let frame = try XCTUnwrap(shown)
    let now = await session.currentTime.seconds
    XCTAssertEqual(frame.presentationTime.seconds, now, accuracy: 0.25, "10 frames a second")
    let moved = try await advance(of: session, over: 0.5)
    XCTAssertEqual(moved, 0.5, accuracy: 0.1)
  }

  /// Back a long way: the pictures come back with the sound. While the
  /// player was still getting there, its clock read the old place, and the
  /// new pictures, taken for late, were skipped far ahead of the sound.
  func testASeekBackKeepsThePictureWithTheSound() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let session = try await session(videoRenderer: renderer)
    try await play(session)
    try await session.seek(to: CMTime(seconds: 11, preferredTimescale: 600))
    try await Task.sleep(nanoseconds: 500_000_000)
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    var shown: [PresentedFrame] = []
    // Two seconds of real time, not a count of turns: drawing is slower on a busy machine.
    let started = ContinuousClock.now
    while ContinuousClock.now - started < .seconds(2) {
      if let frame = try await session.renderVideoFrame() { shown.append(frame) }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let last = try XCTUnwrap(shown.last)
    let now = await session.currentTime.seconds
    let elapsed = (ContinuousClock.now - started).inSeconds
    XCTAssertEqual(now, 1 + elapsed, accuracy: 0.5)
    XCTAssertEqual(last.presentationTime.seconds, now, accuracy: 0.25, "10 frames a second")
    XCTAssertGreaterThan(shown.count, 10, "the picture moves")
  }

  /// Reading two seconds ahead, so that it must go on for the sound to.
  /// Where there is somewhere for sound to go, a clock that does not move
  /// is a failure here, not a reason to skip.
  private func shortReach() async throws -> (PlaybackSession, OffscreenVideoRenderer) {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let engine = AVAudioEngine()
    try XCTSkipIf(engine.outputNode.outputFormat(forBus: 0).channelCount == 0, "no audio output device here")
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(value: 1, timescale: 20))
    let reach = BufferingConfiguration(startThreshold: 0.5, resumeThreshold: 1, lowWatermark: 0.25, target: 2)
    return (try await session(videoRenderer: renderer, buffering: reach), renderer)
  }

  /// In the background the picture is not decoded; the sound plays on.
  /// Reading measured by the picture stopped with it, and the system player
  /// ran dry a few seconds later.
  func testTheSoundPlaysOnWithThePictureSuspended() async throws {
    let (session, _) = try await shortReach()
    try await session.play()
    await session.setVideoSuspended(true)
    for _ in 0..<500 where await session.currentTime.seconds < 9 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let now = await session.currentTime.seconds
    XCTAssertGreaterThanOrEqual(now, 9, "still playing")
  }

  /// Picture in picture in the background shows nothing: no picture is
  /// taken, and decoding waits. The sound plays on.
  func testTheSoundPlaysOnWhenNoPictureIsTaken() async throws {
    let (session, _) = try await shortReach()
    try await session.play()
    for _ in 0..<500 where await session.currentTime.seconds < 9 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let now = await session.currentTime.seconds
    XCTAssertGreaterThanOrEqual(now, 9, "still playing")
  }

  /// Given only garbage, the system player does not play: the engine
  /// decodes the track from where playback stands, and says why.
  func testAPlayerThatCannotPlayGivesTheSoundBack() async throws {
    let session = try await session(server: GarblingServer())
    try await session.play()
    var route = await session.audioRoute
    for _ in 0..<1_000 where route == .systemPlayer {
      try await Task.sleep(nanoseconds: 10_000_000)
      route = await session.audioRoute
    }
    guard case .engineAfterFallback = route else { return XCTFail("still \(route)") }
    for _ in 0..<500 where await session.currentTime.seconds <= 0.05 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard await session.currentTime.seconds > 0.05 else { throw XCTSkip("no audio output device here") }
    let moved = try await advance(of: session, over: 1)
    XCTAssertEqual(moved, 1, accuracy: 0.15, "decoded here, it plays on")
  }

  func testAServerThatCannotListenLeavesTheSoundHere() async throws {
    let session = try await session(server: RefusingServer())
    let route = await session.audioRoute
    guard case .engineAfterFallback(.serverUnavailable) = route else { return XCTFail("\(route)") }
    try await play(session)
    let moved = try await advance(of: session, over: 1)
    XCTAssertEqual(moved, 1, accuracy: 0.15)
  }
}
