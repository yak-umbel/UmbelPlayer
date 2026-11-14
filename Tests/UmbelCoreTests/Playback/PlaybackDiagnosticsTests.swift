import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class DiagnosticHostTime: HostTimeSource, @unchecked Sendable {
  var seconds = 0.0
  var now: CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
}

private actor DiagnosticVideoRenderer: SystemDecodedVideoShowing {
  let showsSystemDecodedDV = true
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { get async { .zero } }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

final class PlaybackDiagnosticsTests: XCTestCase {
  func testBoundedHistoryReportsLostEventsAndSupportsIncrementalReading() throws {
    let diagnostics = UmbelPlaybackDiagnostics(capacity: 2)
    diagnostics.record("first", values: ["pts": 1])
    diagnostics.record("second", values: ["pts": 2])
    diagnostics.record("third", values: ["pts": 3])
    let snapshot = diagnostics.snapshot()
    XCTAssertEqual(snapshot.events.map(\.name), ["second", "third"])
    XCTAssertEqual(snapshot.events.map(\.sequence), [2, 3])
    XCTAssertEqual(snapshot.overwrittenEventCount, 1)
    XCTAssertEqual(snapshot.latestSequence, 3)
    XCTAssertEqual(diagnostics.snapshot(after: 2).events.map(\.name), ["third"])
    XCTAssertTrue(diagnostics.snapshot(after: 3).events.isEmpty)
    let encoded = try JSONEncoder().encode(snapshot.events)
    let decoded = try JSONDecoder().decode([UmbelPlaybackDiagnosticEvent].self, from: encoded)
    XCTAssertEqual(decoded, snapshot.events)
    XCTAssertEqual(Set(decoded.map(\.traceID)), [diagnostics.id])
  }

  func testInvalidTimesDoNotPreventJSONExport() throws {
    let diagnostics = UmbelPlaybackDiagnostics(capacity: 2)
    diagnostics.record("missing_time", values: ["pts": .nan, "dts": .infinity, "clock": 5])
    let event = try XCTUnwrap(diagnostics.snapshot().events.first)
    XCTAssertNil(event.values["pts"])
    XCTAssertNil(event.values["dts"])
    XCTAssertEqual(event.values["clock"], 5)
    XCTAssertNoThrow(try JSONEncoder().encode(event))
  }

  func testFutureQueueHeadIsReportedAtTheClockUsedForThatTake() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let queue = VideoFrameQueue(capacity: 3, tolerance: time(0.02))
    await queue.setDiagnostics(diagnostics, output: "test")
    await queue.enqueue(try frame(10))
    _ = await queue.take(at: time(10))
    for pts in [15.0, 15.04, 15.08] { await queue.enqueue(try frame(pts)) }
    let result = await queue.take(at: time(11))
    XCTAssertNil(result.frame)
    let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.name == "video_take" })
    XCTAssertEqual(event.labels["reason"], "future")
    XCTAssertEqual(event.values["clock"], 11)
    XCTAssertEqual(event.values["headPTS"], 15)
    XCTAssertEqual(event.values["headMinusClock"], 4)
    XCTAssertEqual(event.values["queueDepth"], 3)
    let depth = await queue.depth
    XCTAssertEqual(depth, 3, "diagnosing a future head must not consume it")
    let due = await queue.take(at: time(15))
    XCTAssertEqual(due.frame?.presentationTime.seconds, 15)
  }

  func testEmptyAndSeededTakesHaveDifferentReasons() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let queue = VideoFrameQueue(capacity: 3, tolerance: time(0.02))
    await queue.setDiagnostics(diagnostics, output: "test")
    _ = await queue.take(at: time(11))
    await queue.seed(try frame(10))
    _ = await queue.take(at: time(11))
    let takes = diagnostics.snapshot().events.filter { $0.name == "video_take" }
    XCTAssertEqual(takes.map { $0.labels["reason"] }, ["empty", "seeded"])
    XCTAssertNil(takes.first?.values["headPTS"])
    XCTAssertEqual(takes.last?.values["framePTS"], 10)
  }

  func testFutureTakeRecordsDroppedFramesAndChangedHeadImmediately() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let queue = VideoFrameQueue(capacity: 3, tolerance: time(0.02))
    await queue.setDiagnostics(diagnostics, output: "test")
    await queue.enqueue(try frame(10))
    _ = await queue.take(at: time(10))
    for pts in [15.0, 20.0] { await queue.enqueue(try frame(pts)) }
    _ = await queue.take(at: time(11))
    let before = diagnostics.snapshot().latestSequence
    let result = await queue.take(at: time(18))
    XCTAssertNil(result.frame)
    XCTAssertEqual(result.dropped, 1)
    let event = try XCTUnwrap(diagnostics.snapshot(after: before).events.first { $0.name == "video_take" })
    XCTAssertEqual(event.labels["reason"], "future")
    XCTAssertEqual(event.values["clock"], 18)
    XCTAssertEqual(event.values["headPTS"], 20)
    XCTAssertEqual(event.values["headMinusClock"], 2)
    XCTAssertEqual(event.values["dropped"], 1)
    XCTAssertEqual(event.values["queueDepth"], 1)
  }

  func testFutureTakeRecordsChangedDepthWithTheSameHeadImmediately() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let queue = VideoFrameQueue(capacity: 3, tolerance: time(0.02))
    await queue.setDiagnostics(diagnostics, output: "test")
    await queue.enqueue(try frame(10))
    _ = await queue.take(at: time(10))
    await queue.enqueue(try frame(15))
    _ = await queue.take(at: time(11))
    let before = diagnostics.snapshot().latestSequence
    await queue.enqueue(try frame(20))
    _ = await queue.take(at: time(11.01))
    let event = try XCTUnwrap(diagnostics.snapshot(after: before).events.first { $0.name == "video_take" })
    XCTAssertEqual(event.values["headPTS"], 15)
    XCTAssertEqual(event.values["queueDepth"], 2)
  }

  func testIdenticalFutureTakesRemainThrottled() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let queue = VideoFrameQueue(capacity: 3, tolerance: time(0.02))
    await queue.setDiagnostics(diagnostics, output: "test")
    await queue.enqueue(try frame(10))
    _ = await queue.take(at: time(10))
    await queue.enqueue(try frame(15))
    _ = await queue.take(at: time(11))
    let before = diagnostics.snapshot().latestSequence
    _ = await queue.take(at: time(11.01))
    XCTAssertTrue(diagnostics.snapshot(after: before).events.isEmpty)
  }

  func testClockRecordsResumeAndAnAudioAnchorThatMovesItBack() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let host = DiagnosticHostTime()
    let clock = PresentationClock(hostTime: host, diagnostics: diagnostics)
    await clock.reset(to: time(100))
    await clock.setRate(1)
    host.seconds = 2
    await clock.setRate(0)
    host.seconds = 12
    await clock.setRate(1)
    let resumed = await clock.now()
    XCTAssertEqual(resumed.seconds, 102)
    await clock.adopt(RenderAnchor(mediaTime: time(100), hostTime: host.now))
    let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.name == "clock_adopt" })
    XCTAssertEqual(event.values["positionBefore"], 102)
    XCTAssertEqual(event.values["positionAfter"], 100)
    XCTAssertEqual(event.values["correction"], -2)
    XCTAssertEqual(event.values["anchorHost"], 12)
    let adopted = await clock.now()
    XCTAssertEqual(adopted.seconds, 100, "diagnostics must not reject or adjust anchors")
  }

  func testContinuityReportsTheGapItFillsWithoutChangingSamples() throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    var continuity = AudioContinuity(diagnostics: diagnostics)
    func audio(_ start: Double) -> AudioFrame {
      AudioFrame(presentationTime: time(start), sampleRate: 100, channelCount: 1,
                 frameCount: 10, samples: Array(repeating: 1, count: 10))
    }
    _ = continuity.frames(for: audio(1))
    let frames = continuity.frames(for: audio(2.1))
    XCTAssertEqual(frames.dropLast().reduce(0) { $0 + $1.frameCount }, 100)
    XCTAssertEqual(frames.last?.presentationTime.seconds ?? -1, 2.1, accuracy: 0.001)
    let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.name == "audio_silence" })
    XCTAssertEqual(event.values["expectedPTS"] ?? -1, 1.1, accuracy: 0.001)
    XCTAssertEqual(event.values["incomingPTS"], 2.1)
    XCTAssertEqual(event.values["silenceDuration"] ?? -1, 1, accuracy: 0.001)
    XCTAssertEqual(event.values["silenceSamples"], 100)
  }

  func testHLSRecordsWhetherAnOffsetWasPreservedOrReanchored() throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    var timeline = HLSRunTimeline(diagnostics: diagnostics)
    timeline.beginRun(startingAt: 0, continuing: false)
    _ = timeline.place(presentation: time(1.48), decode: time(1.4), duration: time(0.04))
    _ = timeline.place(presentation: time(13.44), decode: time(13.4), duration: time(0.04))
    timeline.beginRun(startingAt: 12.03, continuing: true)
    let placed = timeline.place(presentation: time(13.48), decode: time(13.44), duration: time(0.04))
    XCTAssertEqual(placed.presentation.seconds, 12, accuracy: 0.001)
    let anchors = diagnostics.snapshot().events.filter { $0.name == "hls_anchor" }
    XCTAssertEqual(anchors.map { $0.labels["decision"] }, ["reanchored", "preserved"])
    XCTAssertEqual(anchors.last?.values["offset"] ?? 0, -1.48, accuracy: 0.001)
    XCTAssertEqual(anchors.last?.values["previousEnd"] ?? 0, 13.48, accuracy: 0.001)
  }

  func testEngineReportsWhyItHasNoAnchorBeforeScheduling() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let output = EngineAudioOutput()
    await output.setPlaybackDiagnostics(diagnostics)
    let anchor = await output.currentAnchor
    XCTAssertNil(anchor)
    XCTAssertEqual(diagnostics.snapshot().events.last?.labels["reason"], "noFirstFrame")
  }

  func testPlaylistPacketsKeepTheirRawAndMappedTimesInTheTrace() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let demux = DemuxSession(source: FixtureServer().source(fixture("hls/ad.m3u8")),
                             diagnostics: diagnostics)
    try await demux.open()
    addTeardownBlock { await demux.close() }
    var packets: [DemuxPacket] = []
    while let packet = try await demux.nextPacket() { packets.append(packet) }
    let events = diagnostics.snapshot().events
    XCTAssertEqual(events.first { $0.name == "demux_open" }?.labels["path"], "playlist")
    let mapped = events.filter { $0.name == "demux_packet" }
    XCTAssertEqual(mapped.count, packets.count)
    for (event, packet) in zip(mapped, packets) {
      XCTAssertEqual(event.values["track"], Double(packet.trackID.rawValue))
      XCTAssertEqual(event.values["mappedPTS"] ?? -1, packet.presentationTime.seconds, accuracy: 0.000001)
      XCTAssertNotNil(event.values["sourcePTS"])
      XCTAssertNotNil(event.values["run"])
    }
    XCTAssertEqual(events.filter { $0.name == "hls_anchor" }.count, 3)
    XCTAssertFalse(events.filter { $0.name == "hls_segment_open" }.isEmpty)
  }

  func testFallbackPathIsIdentifiedBeforePacketsAreDecoded() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let demux = DemuxSession(source: FixtureServer().source(fixture("hls/packed/index.m3u8")),
                             diagnostics: diagnostics)
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let first = try await demux.nextPacket()
    XCTAssertNotNil(first)
    let events = diagnostics.snapshot().events
    XCTAssertEqual(events.first { $0.name == "demux_open" }?.labels["path"], "hlsFallback")
    XCTAssertNotNil(events.last { $0.name == "demux_packet" }?.values["timelineOrigin"])
  }

  func testSessionConnectsDemuxDecodingAndPauseToOneRecorder() async throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let output = VirtualAudioOutput(hostTime: SystemHostTimeSource())
    let session = PlaybackSession(source: try UmbelFileSource(url: fixture("audio_only.m4a")),
                                  audioOutput: output, diagnostics: diagnostics)
    addTeardownBlock { await session.stop() }
    try await session.load()
    try await session.play()
    for _ in 0..<200 {
      await output.advance(bySeconds: 0.01)
      if diagnostics.snapshot().events.contains(where: { $0.name == "clock_adopt" }) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await session.pause()
    let events = diagnostics.snapshot().events
    XCTAssertEqual(Set(events.map(\.traceID)), [diagnostics.id])
    for name in ["session_loaded", "demux_packet", "audio_decoded", "clock_adopt", "session_pause"] {
      XCTAssertTrue(events.contains { $0.name == name }, "missing \(name)")
    }
    XCTAssertEqual(events.last { $0.name == "clock_rate" }?.values["rate"], 0)
  }

  func testLoadedSessionReportsSelectedVideoDecodingRoute() async throws {
    let cases: [(String, UmbelVideoDecodingMode, String)] = [
      ("sync_check.mp4", .synchronous, "synchronous"),
      ("sync_check.mp4", .asynchronous, "asynchronous"),
      ("dv_p5.mp4", .asynchronous, "systemManaged")
    ]
    for (name, mode, expected) in cases {
      let diagnostics = UmbelPlaybackDiagnostics()
      let session = PlaybackSession(
        source: try UmbelFileSource(url: fixture(name)),
        videoRenderer: DiagnosticVideoRenderer(), videoDecodingMode: mode,
        diagnostics: diagnostics)
      addTeardownBlock { await session.stop() }
      let before = await session.videoDecodingStatus
      XCTAssertEqual(before, .inactive)
      try await session.load()
      let event = try XCTUnwrap(diagnostics.snapshot().events.last { $0.name == "session_loaded" })
      XCTAssertEqual(event.labels["selectedDecoding"], expected)
    }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  private func frame(_ seconds: Double) throws -> VideoFrame {
    let pixels = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(
      width: 4, height: 4, luma: 128, cb: 128, cr: 128))
    return VideoFrame(presentationTime: time(seconds), pixelBuffer: pixels,
                      width: 4, height: 4, color: .init(matrix: .bt709, range: .limited))
  }
}
