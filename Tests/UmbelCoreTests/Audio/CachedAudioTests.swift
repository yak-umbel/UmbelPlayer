import CoreMedia
import XCTest
@testable import UmbelCore

private struct FrozenHostTime: HostTimeSource {
  var now: CMTime { .zero }
}

final class CachedAudioTests: XCTestCase {
  private let audio = UmbelTrack.ID(rawValue: 1)

  private func packet(at start: Double, duration: Double, bytes: Int = 16) -> DemuxPacket {
    DemuxPacket(
      trackID: audio, data: Data(count: bytes),
      presentationTime: CMTime(seconds: start, preferredTimescale: 1_000),
      decodeTime: CMTime(seconds: start, preferredTimescale: 1_000),
      duration: CMTime(seconds: duration, preferredTimescale: 1_000),
      isKeyframe: true)
  }

  private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(
      start: CMTime(seconds: start, preferredTimescale: 1_000),
      duration: CMTime(seconds: duration, preferredTimescale: 1_000))
  }

  func testConsumedPacketsRemainAvailableWithDisjointCoverage() async {
    let cache = PacketCache(
      configuration: .init(), measuredTrack: audio, audioTracks: [audio],
      cachedAudio: .init(maxDuration: 10, maxBytes: 1_000))
    await cache.append(packet(at: 0, duration: 0.1))
    await cache.append(packet(at: 0.1, duration: 0.1))
    await cache.append(packet(at: 0.4, duration: 0.1))
    _ = await cache.take(from: audio, keeping: [audio])
    _ = await cache.take(from: audio, keeping: [audio])
    _ = await cache.take(from: audio, keeping: [audio])

    let coverage = await cache.cachedAudioRanges(for: audio)
    XCTAssertEqual(coverage.map(\.start.seconds), [0, 0.4])
    XCTAssertEqual(coverage.map(\.duration.seconds), [0.2, 0.1])
    do {
      _ = try await cache.snapshotAudio(for: audio, range: range(0.1, 0.35))
      XCTFail("Expected missing coverage")
    } catch {
      guard case CachedAudioError.missingCoverage = error else {
        return XCTFail("Expected missing coverage, got \(error)")
      }
    }
  }

  func testRetentionEvictsByBothDurationAndBytes() async throws {
    let cache = PacketCache(
      configuration: .init(), measuredTrack: audio, audioTracks: [audio],
      cachedAudio: .init(maxDuration: 0.2, maxBytes: 32))
    await cache.append(packet(at: 0, duration: 0.1))
    await cache.append(packet(at: 0.1, duration: 0.1))
    await cache.append(packet(at: 0.2, duration: 0.1))
    let durationLimited = await cache.cachedAudioRanges(for: audio)
    XCTAssertEqual(durationLimited.map(\.start.seconds), [0.1])
    XCTAssertEqual(durationLimited.map(\.duration.seconds), [0.2])

    await cache.append(packet(at: 0.3, duration: 0.1, bytes: 24))
    let coverage = await cache.cachedAudioRanges(for: audio)
    XCTAssertEqual(coverage.map(\.start.seconds), [0.3])
    XCTAssertEqual(coverage.map(\.duration.seconds), [0.1])
  }

  func testEarlierTimestampCannotExtendRetentionWindow() async {
    let cache = PacketCache(
      configuration: .init(), measuredTrack: audio, audioTracks: [audio],
      cachedAudio: .init(maxDuration: 1, maxBytes: 1_000))
    await cache.append(packet(at: 10, duration: 0.1))
    await cache.append(packet(at: 0, duration: 0.1))
    let coverage = await cache.cachedAudioRanges(for: audio)
    XCTAssertEqual(coverage.map(\.start.seconds), [10])
  }

  func testSnapshotIncludesLateArrivingPacketInsideCoveredRange() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    guard let track = await demux.tracks.first(where: { $0.kind == .audio }),
          let parameters = await demux.codecParameters(for: track.id) else {
      return XCTFail("Fixture has no audio parameters")
    }
    let cache = PacketCache(
      configuration: .init(), measuredTrack: track.id, audioTracks: [track.id],
      cachedAudio: .init(maxDuration: 10, maxBytes: 1_000),
      audioParameters: [track.id: parameters])
    for (time, marker) in [(0.0, UInt8(1)), (2.0, 2), (1.0, 3)] {
      let base = packet(at: time, duration: 1)
      await cache.append(DemuxPacket(
        trackID: track.id, data: Data([marker]),
        presentationTime: base.presentationTime, decodeTime: base.decodeTime,
        duration: base.duration, isKeyframe: true))
    }
    let coverage = await cache.cachedAudioRanges(for: track.id)
    XCTAssertEqual(coverage.map(\.duration.seconds), [3])
    let snapshot = try await cache.snapshotAudio(for: track.id, range: range(0, 2))
    XCTAssertEqual(snapshot.packets.map(\.presentationTime.seconds), [0, 2, 1])
    XCTAssertEqual(snapshot.packets.map { $0.data.first }, [1, 2, 3])
  }

  func testFlushClearsCachedCoverage() async throws {
    let cache = PacketCache(
      configuration: .init(), measuredTrack: audio, audioTracks: [audio],
      cachedAudio: .init(maxDuration: 10, maxBytes: 1_000))
    await cache.append(packet(at: 0, duration: 0.1))
    await cache.flush()
    let coverage = await cache.cachedAudioRanges(for: audio)
    XCTAssertTrue(coverage.isEmpty)
  }

  func testTrimmingKeepsPlanarSamplesAtRequestedTime() {
    let frame = AudioFrame(
      presentationTime: CMTime(seconds: 1, preferredTimescale: 1_000),
      sampleRate: 10, channelCount: 2, frameCount: 6,
      samples: [0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15])
    let trimmed = frame.trimmed(to: range(1.15, 0.3))
    XCTAssertNotNil(trimmed)
    XCTAssertEqual(trimmed?.presentationTime.seconds ?? -1, 1.2, accuracy: 0.0001)
    XCTAssertEqual(trimmed?.frameCount, 2)
    XCTAssertEqual(trimmed?.samples, [2, 3, 12, 13])
  }

  func testSessionExtractsRealPCMWithoutMovingPausedPlayback() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture),
      cachedAudio: .init(maxDuration: 5, maxBytes: 1_000_000))
    addTeardownBlock { await session.stop() }
    try await session.load()
    guard let track = await session.tracks.first(where: { $0.kind == .audio }) else {
      return XCTFail("Fixture has no audio track")
    }
    try await session.play()
    for _ in 0..<100 {
      if await session.cachedAudioRanges(for: track.id).contains(where: { $0.end.seconds > 1 }) {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await session.pause()
    let position = await session.currentTime
    let phase = await session.phase
    let extraction = try await session.extractCachedAudio(
      for: track.id, range: range(0.25, 0.25))
    XCTAssertFalse(extraction.frames.isEmpty)
    XCTAssertTrue(extraction.frames.flatMap(\.samples).contains { abs($0) > 0.001 })
    XCTAssertEqual(extraction.frames[0].sampleRate, 48_000)
    XCTAssertEqual(extraction.frames[0].channelCount, 2)
    let channel = extraction.frames.flatMap { Array($0.samples.prefix($0.frameCount)) }
    let crossings = zip(channel, channel.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
    XCTAssertEqual(crossings, 110, accuracy: 3)
    XCTAssertTrue(extraction.coveredRanges.allSatisfy {
      $0.start.seconds >= 0.25 && $0.end.seconds <= 0.5
    })
    let after = await session.currentTime
    let afterPhase = await session.phase
    XCTAssertEqual(after.seconds, position.seconds, accuracy: 0.001)
    XCTAssertEqual(afterPhase, phase)
  }

  func testExtractionAndMissingCoverageLeaveActivePlaybackUntouched() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let host = FrozenHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture), audioOutput: output,
      hostTime: host, cachedAudio: .init(maxDuration: 5, maxBytes: 1_000_000))
    addTeardownBlock { await session.stop() }
    try await session.load()
    guard let track = await session.tracks.first(where: { $0.kind == .audio }) else {
      return XCTFail("Fixture has no audio track")
    }
    try await session.play()
    for _ in 0..<100 {
      if await output.pendingSeconds >= 1, await session.phase == .playing { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let pending = await output.pendingSeconds
    XCTAssertGreaterThanOrEqual(pending, 1)
    let position = await session.currentTime
    let phase = await session.phase
    XCTAssertEqual(phase, .playing)

    let pcm = try await session.extractCachedAudio(for: track.id, range: range(0.25, 0.25))
    XCTAssertFalse(pcm.frames.isEmpty)
    do {
      _ = try await session.extractCachedAudio(for: track.id, range: range(10, 0.1))
      XCTFail("Expected missing coverage")
    } catch {
      guard case CachedAudioError.missingCoverage = error else {
        return XCTFail("Expected missing coverage, got \(error)")
      }
    }
    let after = await session.currentTime
    let afterPending = await output.pendingSeconds
    let afterPhase = await session.phase
    XCTAssertEqual(after.seconds, position.seconds, accuracy: 0.001)
    XCTAssertEqual(afterPending, pending, accuracy: 0.001)
    XCTAssertEqual(afterPhase, .playing)
  }

  func testExtractionRejectsPCMOverConfiguredByteLimit() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture),
      cachedAudio: .init(maxDuration: 5, maxBytes: 1_000_000, maxDecodedBytes: 1_024))
    addTeardownBlock { await session.stop() }
    try await session.load()
    guard let track = await session.tracks.first(where: { $0.kind == .audio }) else {
      return XCTFail("Fixture has no audio track")
    }
    try await session.play()
    for _ in 0..<100 {
      if await session.cachedAudioRanges(for: track.id).contains(where: { $0.end.seconds > 1 }) {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    do {
      _ = try await session.extractCachedAudio(for: track.id, range: range(0.25, 0.25))
      XCTFail("Expected PCM output limit")
    } catch {
      guard case CachedAudioError.outputLimitExceeded(maxBytes: 1_024) = error else {
        return XCTFail("Expected PCM output limit, got \(error)")
      }
    }
  }

  func testTakenSnapshotDecodesAfterCacheFlush() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture),
      cachedAudio: .init(maxDuration: 5, maxBytes: 1_000_000))
    addTeardownBlock { await session.stop() }
    try await session.load()
    guard let track = await session.tracks.first(where: { $0.kind == .audio }) else {
      return XCTFail("Fixture has no audio track")
    }
    try await session.play()
    for _ in 0..<100 {
      if await session.cachedAudioRanges(for: track.id).contains(where: { $0.end.seconds > 1 }) {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let snapshot = try await session.cache!.snapshotAudio(for: track.id, range: range(0.25, 0.25))
    await session.pipeline!.flushCache()
    let remaining = await session.cachedAudioRanges(for: track.id)
    XCTAssertTrue(remaining.isEmpty)
    let extraction = try await CachedAudioExtractor.extract(snapshot)
    XCTAssertFalse(extraction.frames.isEmpty)
  }

  func testFormatParametersSurviveEvictionOfTheirFirstPacket() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture))
    try await demux.open()
    defer { Task { await demux.close() } }
    guard let track = await demux.tracks.first(where: { $0.kind == .audio }),
          let initial = await demux.codecParameters(for: track.id),
          let changed = await demux.codecParameters(for: track.id) else {
      return XCTFail("Fixture has no audio parameters")
    }
    let cache = PacketCache(
      configuration: .init(), measuredTrack: audio, audioTracks: [audio],
      cachedAudio: .init(maxDuration: 0.2, maxBytes: 1_000),
      audioParameters: [audio: initial])
    var marker = packet(at: 0, duration: 0.1)
    marker.decoderParameters = changed
    await cache.append(marker)
    await cache.append(packet(at: 0.1, duration: 0.1))
    await cache.append(packet(at: 0.2, duration: 0.1))
    let snapshot = try await cache.snapshotAudio(for: audio, range: range(0.1, 0.1))
    XCTAssertTrue(snapshot.parameters === changed)
  }

  func testFormatParametersOnUnretainedPacketCarryToLaterPackets() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    guard let track = await demux.tracks.first(where: { $0.kind == .audio }),
          let initial = await demux.codecParameters(for: track.id),
          let changed = await demux.codecParameters(for: track.id) else {
      return XCTFail("Fixture has no audio parameters")
    }
    let cache = PacketCache(
      configuration: .init(), measuredTrack: audio, audioTracks: [audio],
      cachedAudio: .init(maxDuration: 1, maxBytes: 1_000),
      audioParameters: [audio: initial])
    var marker = packet(at: 0, duration: 0)
    marker.decoderParameters = changed
    await cache.append(marker)
    await cache.append(packet(at: 0.1, duration: 0.1))
    let snapshot = try await cache.snapshotAudio(for: audio, range: range(0.1, 0.1))
    XCTAssertTrue(snapshot.parameters === changed)
  }

  func testCancelledExtractionThrowsCancellationError() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/audio_only.m4a")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture),
      cachedAudio: .init(maxDuration: 5, maxBytes: 1_000_000))
    addTeardownBlock { await session.stop() }
    try await session.load()
    guard let track = await session.tracks.first(where: { $0.kind == .audio }) else {
      return XCTFail("Fixture has no audio track")
    }
    try await session.play()
    for _ in 0..<100 {
      if await session.cachedAudioRanges(for: track.id).contains(where: { $0.end.seconds > 1 }) {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let requested = range(0.25, 0.25)
    let trackID = track.id
    let extraction = Task { () throws -> CachedAudioExtraction in
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.extractCachedAudio(for: trackID, range: requested)
    }
    do {
      _ = try await extraction.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testCancellationInterruptsLongDecodeBetweenPackets() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/seek_grid.mp4")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture),
      cachedAudio: .init(maxDuration: 31, maxBytes: 8_000_000))
    addTeardownBlock { await session.stop() }
    try await session.load()
    guard let track = await session.tracks.first(where: { $0.kind == .audio }) else {
      return XCTFail("Fixture has no audio track")
    }
    try await session.play()
    let requested = range(0.1, 29)
    for _ in 0..<300 {
      if await session.cachedAudioRanges(for: track.id).contains(where: {
        $0.start <= requested.start && $0.end >= requested.end
      }) {
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let snapshot = try await session.cache!.snapshotAudio(for: track.id, range: requested)
    let extraction = Task { try await CachedAudioExtractor.extract(snapshot) }
    await Task.yield()
    extraction.cancel()
    do {
      _ = try await extraction.value
      XCTFail("Expected cancellation during packet decoding")
    } catch is CancellationError {
      // Expected.
    }
  }
}
