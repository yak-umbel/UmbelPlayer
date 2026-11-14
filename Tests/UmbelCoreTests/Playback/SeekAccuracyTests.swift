import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private enum Fixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }
}

private final class FixedHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// An output double that records what is queued.
///
/// Checks on content need the samples themselves, and `VirtualAudioOutput`
/// records only durations. `stop()` clears the record, so what is left after
/// a seek is exactly what was queued after it.
private actor RecordingAudioOutput: AudioOutput {
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Float, muted: Bool) {}
  private var frames: [AudioFrame] = []

  var currentAnchor: RenderAnchor? { nil }

  func prepare(sampleRate: Double, channelCount: Int) async throws {}
  func enqueue(_ frame: AudioFrame) async throws { frames.append(frame) }
  func start() async throws {}
  func pause() async {}
  /// Seeks flush rather than stop; to this double they are the same: drop
  /// what was queued.
  func flush() async { frames.removeAll() }
  func stop() async { frames.removeAll() }

  var firstFrameTime: CMTime? { frames.first?.presentationTime }

  var frameTimes: [CMTime] { frames.map(\.presentationTime) }

  /// The first frame's RMS energy. The fixture sounds only in the first
  /// tenth of each second.
  var firstFrameEnergy: Float {
    guard let frame = frames.first, !frame.samples.isEmpty else { return 0 }
    let sum = frame.samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sum / Float(frame.samples.count)).squareRoot()
  }
}

/// A source that reads slowly on purpose.
///
/// It stretches a seek out long enough for a second to come in — two seeks
/// overlapping being what the generation is for — which a local file at
/// normal speed is too quick to produce.
private struct SlowSource: UmbelRandomAccessSource {
  let inner: UmbelFileSource

  var contentLength: Int64? { get async { await inner.contentLength } }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    try await Task.sleep(nanoseconds: 50_000_000)
    return try await inner.read(offset: offset, maxLength: maxLength)
  }

  func invalidate() async { await inner.invalidate() }
}

final class SeekAccuracyTests: XCTestCase {
  private func makeRendererOrSkip() throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
  }

  /// Waits for feeding to put frames from after the seek into the renderer.
  /// Polling rather than a fixed sleep: that fails now and then on a slow
  /// machine and waits for nothing on a fast one.
  private func waitForFrame(in renderer: OffscreenVideoRenderer) async throws {
    for _ in 0..<100 {
      if await renderer.queueDepth > 0 { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("no frame reached the renderer within two seconds of the seek")
  }

  private func seekedSession(
    to seconds: Double,
    renderer: OffscreenVideoRenderer,
    output: RecordingAudioOutput
  ) async throws -> PlaybackSession {
    let source = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let session = PlaybackSession(
      source: source, audioOutput: output, videoRenderer: renderer,
      hostTime: FixedHostTime())
    try await session.load()
    try await session.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    try await waitForFrame(in: renderer)
    return session
  }

  /// Exactness itself: the first frame out after a seek is not before the
  /// target. A seek to keyframes would land at 2.0 s, and this fails.
  func testFirstFrameIsNotBeforeTheTarget() async throws {
    let renderer = try makeRendererOrSkip()
    let output = RecordingAudioOutput()
    let session = try await seekedSession(to: 3.5, renderer: renderer, output: output)
    addTeardownBlock { await session.stop() }

    let presented = try await session.renderVideoFrame()
    let frame = try XCTUnwrap(presented, "there is a frame to present at the target")
    XCTAssertGreaterThanOrEqual(
      frame.presentationTime.seconds, 3.5 - 0.001,
      "the first frame after the seek is not before the target — before it is a seek to keyframes")

    let recordedTime = await output.firstFrameTime
    let audioTime = try XCTUnwrap(recordedTime, "audio is queued after the seek")
    XCTAssertGreaterThanOrEqual(audioTime.seconds, 3.5 - 0.001, "nor is the audio before the target")
  }

  /// On content: the picture at 3.5 s is dark. The keyframe at 2.0 s is
  /// white, so this tells an exact seek from an inexact one.
  func testSeekingIntoTheDarkStretchShowsDark() async throws {
    let renderer = try makeRendererOrSkip()
    let output = RecordingAudioOutput()
    let session = try await seekedSession(to: 3.5, renderer: renderer, output: output)
    addTeardownBlock { await session.stop() }

    _ = try await session.renderVideoFrame()
    let pixel = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertLessThan(Int(pixel.r), 100, "dark at 3.5 s; landing at 2.0 s would be white")

    let energy = await output.firstFrameEnergy
    XCTAssertLessThan(energy, 0.01, "silent at 3.5 s")
  }

  /// On content: at 3.0 s the picture is white and the sound has energy.
  func testSeekingOntoTheFlashShowsBright() async throws {
    let renderer = try makeRendererOrSkip()
    let output = RecordingAudioOutput()
    let session = try await seekedSession(to: 3.0, renderer: renderer, output: output)
    addTeardownBlock { await session.stop() }

    _ = try await session.renderVideoFrame()
    let pixel = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertGreaterThan(Int(pixel.r), 180, "white from 3.0 to 3.1 s")

    let energy = await output.firstFrameEnergy
    XCTAssertGreaterThan(energy, 0.01, "sound with the flash")
  }

  /// Separate fragmented video and audio use different segment boundaries.
  /// Seeking must keep their content together after the first segment and
  /// after seeking back, despite each HTTP range being read sequentially.
  func testSeparateHLSRangesKeepFlashAndSoundTogetherAfterSeeking() async throws {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/hls/alt_fmp4/master.m3u8")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let renderer = try makeRendererOrSkip()
    let output = RecordingAudioOutput()
    let session = PlaybackSession(
      source: source, audioOutput: output, videoRenderer: renderer,
      hostTime: FixedHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }

    for (target, bright) in [(4.04, true), (1.04, true), (4.5, false)] {
      try await session.seek(to: CMTime(seconds: target, preferredTimescale: 600))
      try await waitForFrame(in: renderer)
      let presented = try await session.renderVideoFrame()
      let frame = try XCTUnwrap(presented)
      XCTAssertEqual(frame.presentationTime.seconds, target, accuracy: 0.04)
      let audioTime = await output.firstFrameTime
      XCTAssertEqual(try XCTUnwrap(audioTime).seconds, target, accuracy: 0.025)
      let pixel = try await renderer.readAveragePixel(inRegion: .whole)
      let energy = await output.firstFrameEnergy
      if bright {
        XCTAssertGreaterThan(Int(pixel.r), 180)
        XCTAssertGreaterThan(energy, 0.01, "a tone with the flash at \(target)")
      } else {
        XCTAssertLessThan(Int(pixel.r), 100)
        XCTAssertLessThan(energy, 0.01, "silence with the dark picture at \(target)")
      }
    }
  }

  /// Exercise software AV1 through the real packet routing, preroll,
  /// discard, audio and rendering paths, even on a machine with AV1 hardware.
  func testAV1SoftwareKeepsFlashAndSoundTogetherAfterSeeking() async throws {
    for depth in [8, 10] {
      let demux = DemuxSession(source: try UmbelFileSource(url: Fixture.url("av1_\(depth)bit.mp4")))
      try await demux.open()
      let tracks = await demux.tracks
      let video = try XCTUnwrap(tracks.first { $0.kind == .video })
      let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
      let decoding = VideoDecodeSession(
        decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
      let sound = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: audio.id))
      let renderer = try makeRendererOrSkip()
      try await renderer.prepare(for: video)
      let output = RecordingAudioOutput()
      let clock = PresentationClock(hostTime: FixedHostTime())
      let pipeline = PlaybackPipeline(
        demux: demux, audioOutput: output, videoRenderer: renderer, clock: clock,
        cache: PacketCache(configuration: .init(), measuredTrack: audio.id))
      addTeardownBlock {
        await pipeline.stop()
        await decoding.close()
        await sound.close()
        await demux.close()
      }
      await pipeline.updateRouting(PacketRouting(
        audioID: audio.id, audioSession: sound, videoID: video.id, videoSession: decoding,
        subtitleID: nil, subtitleReceiver: nil, generation: 0))

      for (seconds, bright) in [(4.033333, true), (1.033333, true), (4.5, false)] {
        let target = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        await pipeline.stop()
        await pipeline.flushCache()
        await decoding.flush()
        await sound.flush()
        try await demux.seek(to: target)
        // Stopping releases backpressure; a feeder may have handed over one
        // last old frame. The session clears both outputs again after seek.
        await renderer.flush()
        await output.flush()
        await clock.reset(to: target)
        await pipeline.armDiscardBoth(at: target)
        await pipeline.armPreroll(at: target)
        await pipeline.start()
        try await waitForFrame(in: renderer)
        for _ in 0..<100 where await output.firstFrameTime == nil {
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        let presented = try await renderer.presentFrame(at: target)
        XCTAssertEqual(try XCTUnwrap(presented).presentationTime.seconds, seconds, accuracy: 0.034)
        let audioTime = await output.firstFrameTime
        XCTAssertEqual(try XCTUnwrap(audioTime).seconds, seconds, accuracy: 0.025)
        let pixel = try await renderer.readAveragePixel(inRegion: .whole)
        let energy = await output.firstFrameEnergy
        if bright {
          XCTAssertGreaterThan(Int(pixel.r), 180, "\(depth)-bit flash at \(seconds)")
          XCTAssertGreaterThan(energy, 0.01, "tone with the flash")
        } else {
          XCTAssertLessThan(Int(pixel.r), 100, "\(depth)-bit dark picture at \(seconds)")
          XCTAssertLessThan(energy, 0.01, "silence with the dark picture")
        }
      }
      await pipeline.stop()
    }
  }

  /// When two seeks overlap, the later one wins.
  ///
  /// **Content** is checked, not the clock: both seeks run to the end, the
  /// second naturally sets the clock last, and the clock is bound to be the
  /// later target — true with or without generations, so testing nothing.
  ///
  /// This pins the **outcome**, not the generation mechanism itself: with
  /// every generation check removed it still passes — each `await` in
  /// `seek` touches actors both seeks share, and at every shared resource
  /// the second is queued behind the first, so it always writes last.
  /// Generations are a defence.
  func testLaterSeekWins() async throws {
    let inner = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let output = RecordingAudioOutput()
    let session = PlaybackSession(
      source: SlowSource(inner: inner),
      audioOutput: output,
      hostTime: FixedHostTime())
    try await session.load()
    addTeardownBlock { await session.stop() }

    async let first: Void = session.seek(to: CMTime(seconds: 1.0, preferredTimescale: 600))
    // Let the first reach the slow source's read before sending the second.
    try await Task.sleep(nanoseconds: 60_000_000)
    try await session.seek(to: CMTime(seconds: 8.0, preferredTimescale: 600))
    _ = try? await first

    // Wait for content to really come out. The slow source takes 50 ms a
    // read; plenty of margin.
    var delivered: [CMTime] = []
    for _ in 0..<60 {
      delivered = await output.frameTimes
      if !delivered.isEmpty { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTAssertFalse(delivered.isEmpty, "content keeps coming out after the seek")
    let earliest = delivered.map(\.seconds).min() ?? 0
    XCTAssertGreaterThanOrEqual(earliest, 8.0 - 0.05, "what comes out is the later seek content")
  }
}
