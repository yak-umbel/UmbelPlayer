import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class StillHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Holds three frames and counts what it is given, as the real one would
/// hold them.
private actor CountingRenderer: VideoRenderer {
  private let queue = VideoFrameQueue(capacity: 3, tolerance: CMTime(value: 1, timescale: 50))
  private(set) var received = 0

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}

  func enqueue(_ frame: VideoFrame) async throws {
    received += 1
    await queue.enqueue(frame)
  }

  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async { await queue.flush() }
  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// Takes subtitle packets and drops them.
private actor IgnoringSubtitleReceiver: SubtitlePacketReceiver {
  func receive(_ packet: DemuxPacket) async {}
}

/// A subtitle decoder slow to take what it is handed: routing to it waits
/// until let go.
private actor HeldSubtitleReceiver: SubtitlePacketReceiver {
  private var held: CheckedContinuation<Void, Never>?
  private(set) var isHolding = false

  func receive(_ packet: DemuxPacket) async {
    isHolding = true
    await withCheckedContinuation { held = $0 }
  }

  func letGo() {
    held?.resume()
    held = nil
  }
}

final class PlaybackPipelineTests: XCTestCase {
  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }

  func testBytePressureStartsAvailablePictureBeforeAMissingAudioTrack() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("seek_grid.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let missingAudio = UmbelTrack.ID(rawValue: 99)
    let output = VirtualAudioOutput(hostTime: StillHostTime())
    let renderer = CountingRenderer()
    let cache = PacketCache(
      configuration: .init(startThreshold: 60, target: 100, maximumPacketBytes: 1), measuredTrack: missingAudio)
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: output, videoRenderer: renderer,
      clock: PresentationClock(hostTime: StillHostTime()), cache: cache)
    let videoSession = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    let audioSession = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: audio.id))
    addTeardownBlock { await videoSession.close(); await audioSession.close() }
    await pipeline.updateRouting(PacketRouting(
      audioID: missingAudio, audioSession: audioSession,
      videoID: video.id, videoSession: videoSession, generation: 0))
    addTeardownBlock { await pipeline.stop() }
    try await pipeline.setWantsToPlay(true)
    await pipeline.start()
    try await waitUntilRunning(pipeline)
    let shown = await renderer.received
    XCTAssertGreaterThan(shown, 0, "the available picture has reached its output")
    let running = await pipeline.isRunning
    XCTAssertTrue(running, "byte pressure must not wait forever for audio behind a full picture queue")
    let buffered = await cache.bufferedSeconds
    XCTAssertLessThan(buffered, 60)
  }

  /// A sound track routed with nothing ever to take, beside a picture that
  /// decodes: the picture alone can start once reading stops at the budget.
  private struct MissingSound {
    let pipeline: PlaybackPipeline
    let cache: PacketCache
    let renderer: CountingRenderer
    let video: UmbelTrack.ID
    let routing: PacketRouting
  }

  private func missingSound(maximumPacketBytes: Int) async throws -> MissingSound {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("seek_grid.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let missingAudio = UmbelTrack.ID(rawValue: 99)
    let renderer = CountingRenderer()
    let cache = PacketCache(
      configuration: .init(startThreshold: 60, target: 100, maximumPacketBytes: maximumPacketBytes),
      measuredTrack: missingAudio)
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: VirtualAudioOutput(hostTime: StillHostTime()), videoRenderer: renderer,
      clock: PresentationClock(hostTime: StillHostTime()), cache: cache)
    let videoSession = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    let audioSession = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: audio.id))
    addTeardownBlock { await videoSession.close(); await audioSession.close() }
    let routing = PacketRouting(
      audioID: missingAudio, audioSession: audioSession,
      videoID: video.id, videoSession: videoSession, generation: 0)
    await pipeline.updateRouting(routing)
    addTeardownBlock { await pipeline.stop() }
    return MissingSound(pipeline: pipeline, cache: cache, renderer: renderer, video: video.id, routing: routing)
  }

  /// Waits until the pipeline has been running for a fifth of a second
  /// without a break. Its first run is not steady: with reading held to a
  /// byte budget, it drops out and in again for a moment while reading and
  /// taking take turns, so the first time it is seen running is not yet
  /// started. The wait is generous (ten seconds) because it only matters
  /// when the run never comes.
  private func waitUntilRunning(_ pipeline: PlaybackPipeline) async throws {
    var steady = 0
    for _ in 0..<1000 {
      steady = await pipeline.isRunning ? steady + 1 : 0
      if steady == 20 { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  /// Hidden up to a seek target three seconds in, the picture hands nothing
  /// on for more than two, and the wait for first frames gives up on it.
  /// Its first frame after that still counts: at the budget, what has one
  /// plays.
  func testAPictureFirstShownAfterTheWaitGaveUpOnItStartsAtTheByteBudget() async throws {
    let setup = try await missingSound(maximumPacketBytes: 1)
    await setup.pipeline.armDiscardBoth(at: CMTime(seconds: 3, preferredTimescale: 600))
    try await setup.pipeline.setWantsToPlay(true)
    await setup.pipeline.start()
    try await waitUntilRunning(setup.pipeline)
    let shown = await setup.renderer.received
    XCTAssertGreaterThan(shown, 0, "precondition: the picture reached its output")
    let running = await setup.pipeline.isRunning
    XCTAssertTrue(running, "a first frame handed on after the wait gave up on its track still lets the picture start")
  }

  /// Reading at the byte budget drops the queues of tracks no chain takes.
  /// A track switched to counts as taken from the moment its route is
  /// published, not only once subtitles have been routed as well.
  func testATrackSwitchedToKeepsItsPacketsWhileSubtitlesAreStillRouting() async throws {
    let first = UmbelTrack.ID(rawValue: 1)
    let second = UmbelTrack.ID(rawValue: 2)
    let subtitle = UmbelTrack.ID(rawValue: 3)
    // Never opened: nothing is read but what the test puts in the cache.
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("seek_grid.mp4")))
    let cache = PacketCache(
      configuration: .init(maximumPacketBytes: 10), measuredTrack: first,
      subtitleTracks: [subtitle], audioTracks: [first, second])
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: nil, videoRenderer: nil,
      clock: PresentationClock(hostTime: StillHostTime()), cache: cache)
    await pipeline.updateRouting(PacketRouting(
      audioID: first, audioSession: nil, videoID: nil, videoSession: nil, generation: 0))
    // A line of the subtitle track already past: routing hands it over.
    await cache.append(Self.packet(of: subtitle, bytes: 1))
    _ = await cache.take(from: subtitle, upTo: .positiveInfinity)
    // Read while not yet switched to, and reaching the budget.
    await cache.append(Self.packet(of: second, bytes: 20))

    let receiver = HeldSubtitleReceiver()
    let switching = Task {
      await pipeline.updateRouting(PacketRouting(
        audioID: second, audioSession: nil, videoID: nil, videoSession: nil,
        subtitleID: subtitle, subtitleReceiver: receiver, generation: 0))
    }
    for _ in 0..<500 where !(await receiver.isHolding) {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let holding = await receiver.isHolding
    XCTAssertTrue(holding, "precondition: subtitles are still routing")
    // The reader's next look at the full cache.
    _ = await cache.prepareToRead()
    let kept = await cache.take(from: second, keeping: [second, subtitle])
    await receiver.letGo()
    await switching.value
    XCTAssertEqual(kept?.data.count, 20, "the track switched to is not dropped as unselected")
  }

  /// At the byte budget the picture measures the level in place of a sound
  /// track with nothing to take. A subtitle switch changes neither what the
  /// route measures nor the seek generation, and leaves that as it was.
  func testASubtitleSwitchKeepsThePictureMeasuringForMissingSound() async throws {
    let setup = try await missingSound(maximumPacketBytes: 256)
    try await setup.pipeline.setWantsToPlay(true)
    await setup.pipeline.start()
    try await waitUntilRunning(setup.pipeline)
    let running = await setup.pipeline.isRunning
    XCTAssertTrue(running, "precondition: the picture started without the sound")
    // What is queued stays; nothing reads or takes any more.
    await setup.pipeline.stop()
    let routing = setup.routing
    await setup.pipeline.updateRouting(PacketRouting(
      audioID: routing.audioID, audioSession: routing.audioSession,
      videoID: routing.videoID, videoSession: routing.videoSession,
      subtitleID: UmbelTrack.ID(rawValue: 77), subtitleReceiver: IgnoringSubtitleReceiver(),
      generation: routing.generation))

    let cache = setup.cache
    for _ in 0..<100 where await cache.reachedByteLimit {
      _ = await cache.take(from: setup.video, keeping: [setup.video])
    }
    let readiness = await cache.playbackReadiness
    let next = await cache.take(from: setup.video, keeping: [setup.video])
    XCTAssertNotNil(next, "precondition: pictures are still queued")
    XCTAssertFalse(readiness.isStarving, "the queued picture, not the empty sound, is what runs dry")
  }

  private static func packet(of track: UmbelTrack.ID, bytes: Int) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: bytes), presentationTime: .zero, decodeTime: .invalid,
      duration: CMTime(value: 1, timescale: 10), isKeyframe: true)
  }

  /// After a seek, frames before the target are decoded only if later ones
  /// refer to them. b_frames.mkv from its keyframe at one second to a target
  /// at 1.9: 23 frames, of which only 8 are referred to.
  func testASeekDecodesOnlyWhatTheTargetNeeds() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("b_frames.mkv")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let target = CMTime(seconds: 1.9, preferredTimescale: 600)
    try await demux.seek(to: target)

    let renderer = CountingRenderer()
    let clock = PresentationClock(hostTime: StillHostTime())
    await clock.reset(to: target)
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: nil, videoRenderer: renderer, clock: clock,
      cache: PacketCache(configuration: .init(), measuredTrack: nil))
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    addTeardownBlock { await session.close() }
    await pipeline.updateRouting(
      PacketRouting(
        audioID: nil, audioSession: nil, videoID: video.id, videoSession: session,
        subtitleID: nil, subtitleReceiver: nil, generation: 0))
    addTeardownBlock { await pipeline.stop() }
    await pipeline.armDiscardBoth(at: target)
    await pipeline.armPreroll(at: target)
    await pipeline.start()

    // Paused: decoding runs until the renderer holds three frames and a
    // fourth waits.
    for _ in 0..<200 where await renderer.received < 4 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let shown = await renderer.received
    XCTAssertEqual(shown, 4, "precondition: the target reached")
    let decoded = await session.decodedFrameCount
    // Without skipping, all 23 before the target decode first.
    XCTAssertLessThanOrEqual(
      decoded, 14, "the 8 referred to before the target, then about 4 from it on")
  }

  /// Emptying the cache holds playback back at once, not at the next packet.
  ///
  /// A seek empties the cache and then waits on the demuxer, which over a
  /// network can take seconds. Were the gate left open until feeding resumed,
  /// the session would report playing — and the clock would run — for all of
  /// that wait.
  func testFlushingTheCacheHoldsPlaybackImmediately() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("seek_grid.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })

    let host = StillHostTime()
    let clock = PresentationClock(hostTime: host)
    let output = VirtualAudioOutput(hostTime: host)
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: output, videoRenderer: nil, clock: clock,
      cache: PacketCache(configuration: .init(), measuredTrack: audio.id))
    let decoder = try await demux.makeAudioDecoder(for: audio.id)
    await pipeline.updateRouting(
      PacketRouting(
        audioID: audio.id,
        audioSession: AudioDecodeSession(decoder: decoder),
        videoID: nil, videoSession: nil, subtitleID: nil, subtitleReceiver: nil,
        generation: 0))

    try await pipeline.setWantsToPlay(true)
    await pipeline.start()
    for _ in 0..<200 {
      if await pipeline.isRunning { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let running = await pipeline.isRunning
    XCTAssertTrue(running, "precondition: playing")

    await pipeline.stop()
    await pipeline.flushCache()

    let holding = await pipeline.isRebuffering
    let rate = await clock.rate
    XCTAssertTrue(holding)
    XCTAssertEqual(rate, 0)
  }
}
