import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// Counts an item's time jumps: each seek makes one.
private final class JumpCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var jumps = 0
  private var observer: NSObjectProtocol?

  init(_ player: AVPlayer) {
    observer = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemTimeJumped, object: player.currentItem, queue: nil
    ) { [weak self] _ in self?.lock.withLock { self?.jumps += 1 } }
  }

  var count: Int { lock.withLock { jumps } }

  deinit { observer.map(NotificationCenter.default.removeObserver) }
}

/// The system player's clock as a session's timeline: the film's time is the
/// player's less the track's shift, plus the audio delay.
@MainActor
final class PlayerItemTimelineTests: XCTestCase {
  private func playing(shiftOverride: CMTime? = nil) async throws -> (PlayerItemTimeline, CMTime) {
    let (server, playlist, shift) = try await ServedEAC3.serve()
    addTeardownBlock { await server.unregister(playlist.deletingLastPathComponent()) }
    let mappedShift = shiftOverride ?? shift
    let timeline = PlayerItemTimeline(url: playlist, shift: mappedShift)
    timeline.setLevel(volume: 0, muted: true)
    addTeardownBlock { timeline.close() }
    timeline.set(rate: 1, time: .zero)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    return (timeline, mappedShift)
  }

  func testTheTimeIsThePlayersLessTheShift() async throws {
    let (timeline, shift) = try await playing()
    try await Task.sleep(nanoseconds: 500_000_000)
    let film = timeline.time.seconds
    let player = timeline.player.currentTime().seconds
    XCTAssertEqual(film, player - shift.seconds, accuracy: 0.02)
    let elapsed = try await sleepMeasured(0.5)
    XCTAssertEqual(timeline.time.seconds - film, elapsed, accuracy: 0.1, "it runs")
  }

  func testSettingATimeSeeksThePlayer() async throws {
    let (timeline, _) = try await playing()
    timeline.set(rate: 1, time: CMTime(seconds: 7, preferredTimescale: 600))
    var landed = false
    for _ in 0..<60 {
      if abs(timeline.time.seconds - 7) < 0.3 { landed = true; break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(landed, "the film's 7 s, got \(timeline.time.seconds)")
  }

  /// A seek takes the player a moment. Meanwhile its time is where it goes,
  /// as the synchronizer's is at once: reading where it was, the pictures
  /// took the new ones for minutes late and skipped far ahead of the sound.
  func testWhileASeekIsUnderWayTheTimeIsItsTarget() async throws {
    let (timeline, _) = try await playing()
    try await Task.sleep(nanoseconds: 300_000_000)
    timeline.set(rate: 1, time: CMTime(seconds: 9, preferredTimescale: 600))
    XCTAssertEqual(timeline.time.seconds, 9, accuracy: 0.001, "at once")
    timeline.set(rate: 1, time: CMTime(seconds: 2, preferredTimescale: 600))
    XCTAssertEqual(timeline.time.seconds, 2, accuracy: 0.001, "back, at once")
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    // Under load its clock can start a moment after it says it plays.
    for _ in 0..<150 where timeline.time.seconds < 2.3 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(timeline.time.seconds, 2.4, accuracy: 0.2, "then on from there")
  }

  /// Sound can end before the picture. Its player stops there; the time
  /// runs on at the rate, as the synchronizer's does, or the pictures after
  /// the last sound never came and playback never ended.
  func testTheTimeRunsOnPastTheEndOfTheSound() async throws {
    let (timeline, _) = try await playing()
    let end = try XCTUnwrap(timeline.player.currentItem?.duration.seconds)
    timeline.set(rate: 1, time: CMTime(seconds: end - 1, preferredTimescale: 600))
    for _ in 0..<150 where timeline.time.seconds < end + 0.5 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertGreaterThan(timeline.time.seconds, end + 0.5, "past the sound's end")
    let running = timeline.time.seconds
    let elapsed = try await sleepMeasured(0.3)
    XCTAssertEqual(timeline.time.seconds - running, elapsed, accuracy: 0.1, "at the rate")

    timeline.set(rate: 0, time: timeline.time)
    let held = timeline.time.seconds
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(timeline.time.seconds, held, accuracy: 0.001, "paused there")

    timeline.set(rate: 1, time: CMTime(seconds: 3, preferredTimescale: 600))
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    // Under load its clock can start a moment after it says it plays.
    for _ in 0..<150 where timeline.time.seconds < 3.2 {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(timeline.time.seconds, 3.3, accuracy: 0.2, "and back into the sound")
  }

  func testRateZeroPausesWhereItIs() async throws {
    let (timeline, _) = try await playing()
    let now = timeline.time
    timeline.set(rate: 0, time: now)
    try await Task.sleep(nanoseconds: 300_000_000)
    let held = timeline.time.seconds
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(timeline.time.seconds, held, accuracy: 0.001)
    XCTAssertEqual(timeline.player.timeControlStatus, .paused)
  }

  /// Positive delay: sound later, so the picture is ahead of what is heard.
  func testTheAudioDelayMovesTheFilmsTime() async throws {
    let (timeline, _) = try await playing()
    let before = timeline.time.seconds - timeline.player.currentTime().seconds
    timeline.setAudioDelay(CMTime(seconds: 0.3, preferredTimescale: 1_000))
    let after = timeline.time.seconds - timeline.player.currentTime().seconds
    XCTAssertEqual(after - before, 0.3, accuracy: 0.02)
  }

  /// A picture layer shows by the film's time on the player's clock.
  @MainActor
  func testADisplayLayerFollowsThePlayersClock() async throws {
    let (timeline, _) = try await playing()
    let layer = AVSampleBufferDisplayLayer()
    try timeline.add(QueuedRenderer(renderer: layer))
    let control = try XCTUnwrap(layer.controlTimebase)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(CMTimebaseGetTime(control).seconds, timeline.time.seconds, accuracy: 0.03)
    XCTAssertEqual(CMTimebaseGetRate(control), 1, accuracy: 0.01)
    await timeline.remove(QueuedRenderer(renderer: layer))
    XCTAssertNil(layer.controlTimebase)
  }

  func testBackgroundLayerHandoverFinishesBeforeReturning() async throws {
    let (timeline, _) = try await playing()
    let layer = AVSampleBufferDisplayLayer()
    let queued = QueuedRenderer(renderer: layer)
    try await Task.detached { try timeline.add(queued) }.value
    XCTAssertNotNil(layer.controlTimebase)
    await Task.detached { await timeline.remove(queued) }.value
    XCTAssertNil(layer.controlTimebase)
  }

  @MainActor
  func testDisplayTimeIncludesShiftAndDelayAndStopsWithAudio() async throws {
    let (timeline, _) = try await playing(shiftOverride: CMTime(seconds: 2, preferredTimescale: 600))
    let layer = AVSampleBufferDisplayLayer()
    try timeline.add(QueuedRenderer(renderer: layer))
    let control = try XCTUnwrap(layer.controlTimebase)
    timeline.setAudioDelay(CMTime(seconds: 0.3, preferredTimescale: 600))
    let source = try XCTUnwrap(timeline.player.currentItem?.timebase)
    XCTAssertEqual(CMTimebaseGetTime(source).seconds - timeline.time.seconds, 1.7, accuracy: 0.02)
    XCTAssertEqual(CMTimebaseGetTime(control).seconds, timeline.time.seconds, accuracy: 0.02)
    timeline.set(rate: 0, time: CMTime(seconds: 4, preferredTimescale: 600))
    try await waitForPosition(4, timeline: timeline)
    XCTAssertEqual(timeline.player.currentTime().seconds, 5.7, accuracy: 0.03)
    XCTAssertEqual(CMTimebaseGetTime(control).seconds, 4, accuracy: 0.03)
    XCTAssertEqual(CMTimebaseGetEffectiveRate(control), 0)
  }

  func testNewestSeekAndPauseSupersedePendingPlayback() async throws {
    let (timeline, _) = try await playing()
    timeline.set(rate: 1, time: CMTime(seconds: 9, preferredTimescale: 600))
    timeline.set(rate: 1, time: CMTime(seconds: 4, preferredTimescale: 600))
    timeline.set(rate: 0, time: CMTime(seconds: 2, preferredTimescale: 600))
    XCTAssertEqual(timeline.handoverTime.seconds, 2, accuracy: 0.03)
    try await waitForPosition(2, timeline: timeline)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(timeline.player.rate, 0)
    XCTAssertEqual(timeline.time.seconds, 2, accuracy: 0.03)
  }

  /// A new player's place is only what its playlist asked for: it may start
  /// from the segment's first frame instead. Taken at its word, a seek
  /// played a second early. So its first place is set by a seek.
  func testANewPlayerIsPlacedByASeekFirst() async throws {
    let (server, playlist, shift) = try await ServedEAC3.serve()
    addTeardownBlock { await server.unregister(playlist.deletingLastPathComponent()) }
    let timeline = PlayerItemTimeline(url: playlist, shift: shift)
    addTeardownBlock { timeline.close() }
    timeline.setLevel(volume: 0, muted: true)
    // Ready, as the route waits for before its clock leads.
    for _ in 0..<150 where timeline.player.currentItem?.status != .readyToPlay {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    timeline.setRate(1)
    XCTAssertTrue(timeline.isSeeking, "placed by a seek, not taken at its word")
    try await ServedEAC3.waitUntilPlaying(timeline.player)
  }

  /// Pausing, playing on and changing speed where it stands move no audio:
  /// a seek there flushed the sound, and the speakers clicked.
  func testPausingAndPlayingOnWhereItStandsDoesNotSeek() async throws {
    let (timeline, _) = try await playing()
    try await Task.sleep(nanoseconds: 300_000_000)
    let jumps = JumpCounter(timeline.player)
    timeline.setRate(0)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(timeline.player.timeControlStatus, .paused)
    let held = timeline.time.seconds
    timeline.setRate(1)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    timeline.setRate(1.5)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(timeline.player.rate, 1.5)
    XCTAssertGreaterThan(timeline.time.seconds, held)
    XCTAssertEqual(jumps.count, 0, "no seek")
  }

  func testRateChangesDuringASeekKeepItsTargetAndNewestPause() async throws {
    let (timeline, _) = try await playing()
    let jumps = JumpCounter(timeline.player)
    timeline.set(rate: 1, time: CMTime(seconds: 7, preferredTimescale: 600))
    XCTAssertTrue(timeline.isSeeking)
    timeline.setRate(1.25)
    timeline.setRate(0)
    XCTAssertEqual(timeline.handoverTime.seconds, 7, accuracy: 0.001)
    try await waitForPosition(7, timeline: timeline)
    XCTAssertEqual(timeline.player.rate, 0)
    XCTAssertEqual(jumps.count, 1, "the accepted seek lands once")
    timeline.setRate(2)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    XCTAssertEqual(timeline.player.rate, 2)
    XCTAssertFalse(timeline.isSeeking)
  }

  func testQueuedRateChangeDoesNotUndoANewerPause() async throws {
    let (timeline, _) = try await playing()
    try await Task.sleep(nanoseconds: 300_000_000)
    DispatchQueue.global().sync { timeline.setRate(2) }
    timeline.setRate(0)
    let held = timeline.time.seconds
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(timeline.player.rate, 0)
    XCTAssertEqual(timeline.time.seconds, held, accuracy: 0.03)
  }

  /// Speed changes keep the pitch as the engine's renderer does.
  func testItChangesSpeedAsTheEnginesRendererDoes() async throws {
    let (server, playlist, shift) = try await ServedEAC3.serve()
    addTeardownBlock { await server.unregister(playlist.deletingLastPathComponent()) }
    let timeline = PlayerItemTimeline(url: playlist, shift: shift)
    addTeardownBlock { timeline.close() }
    let engine = try XCTUnwrap(
      SystemAudioRenderer(volume: 0, onDiscarded: {}).queued.renderer as? AVSampleBufferAudioRenderer)
    XCTAssertEqual(timeline.player.currentItem?.audioTimePitchAlgorithm, .spectral)
    XCTAssertEqual(timeline.player.currentItem?.audioTimePitchAlgorithm, engine.audioTimePitchAlgorithm)
  }

  func testTheRateAskedForIsKept() async throws {
    let (server, playlist, shift) = try await ServedEAC3.serve()
    addTeardownBlock { await server.unregister(playlist.deletingLastPathComponent()) }
    let timeline = PlayerItemTimeline(url: playlist, shift: shift)
    XCTAssertEqual(timeline.requestedRate, 0)
    timeline.set(rate: 1.5, time: .zero)
    XCTAssertEqual(timeline.requestedRate, 1.5)
    timeline.set(rate: 0, time: .zero)
    XCTAssertEqual(timeline.requestedRate, 0)
    timeline.set(rate: 1, time: .zero)
    timeline.close()
    XCTAssertEqual(timeline.requestedRate, 0, "nothing more plays")
  }

  @MainActor
  func testCloseCancelsPlaybackAndReleasesAttachedLayers() async throws {
    let (timeline, _) = try await playing()
    let layer = AVSampleBufferDisplayLayer()
    try timeline.add(QueuedRenderer(renderer: layer))
    timeline.set(rate: 1, time: CMTime(seconds: 8, preferredTimescale: 600))
    timeline.close()
    timeline.set(rate: 1, time: .zero)
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertNil(timeline.player.currentItem)
    XCTAssertEqual(timeline.player.rate, 0)
    XCTAssertNil(layer.controlTimebase)
    XCTAssertThrowsError(try timeline.add(QueuedRenderer(renderer: layer)))
  }

  @MainActor
  func testCannotTakeAnAudioRendererOrAnotherTimelinesDisplayLayer() async throws {
    let (timeline, _) = try await playing()
    XCTAssertThrowsError(try timeline.add(QueuedRenderer(renderer: AVSampleBufferAudioRenderer())))
    let layer = AVSampleBufferDisplayLayer()
    var control: CMTimebase?
    XCTAssertEqual(CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &control), noErr)
    layer.controlTimebase = try XCTUnwrap(control)
    XCTAssertThrowsError(try timeline.add(QueuedRenderer(renderer: layer)))
    XCTAssertTrue(layer.controlTimebase === control)
  }

  /// Waits for the last seek to land there. The time says where it goes at
  /// once, so it alone does not tell.
  private func waitForPosition(_ seconds: Double, timeline: PlayerItemTimeline) async throws {
    for _ in 0..<100 {
      if !timeline.isSeeking, abs(timeline.time.seconds - seconds) < 0.03 { return }
      try await Task.sleep(nanoseconds: 30_000_000)
    }
    XCTFail("position did not settle at \(seconds): \(timeline.time.seconds)")
  }

  func testControlsFromBackgroundFinishWithoutBlockingTheMainQueue() async throws {
    let (timeline, _) = try await playing()
    let layer = AVSampleBufferDisplayLayer()
    try timeline.add(QueuedRenderer(renderer: layer))
    await Task.detached {
      timeline.set(rate: 0, time: CMTime(seconds: 3, preferredTimescale: 600))
      timeline.setLevel(volume: 0.25, muted: true)
    }.value
    try await waitForPosition(3, timeline: timeline)
    XCTAssertEqual(timeline.player.rate, 0)
    XCTAssertEqual(timeline.player.volume, 0.25)
    XCTAssertTrue(timeline.player.isMuted)
    await Task.detached { timeline.close() }.value
    for _ in 0..<100 where timeline.player.currentItem != nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertNil(timeline.player.currentItem)
    XCTAssertEqual(timeline.player.rate, 0)
    XCTAssertNil(layer.controlTimebase)
  }
}
