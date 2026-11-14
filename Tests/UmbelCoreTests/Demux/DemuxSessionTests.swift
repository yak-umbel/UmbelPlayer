import CoreMedia
import XCTest
@testable import UmbelCore

/// A local file behind a source that reads in order only, standing in for a
/// live stream without needing one.
private actor SequentialOnlySource: UmbelStreamingSource {
  private let data: Data
  private var position = 0

  init(url: URL) throws { self.data = try Data(contentsOf: url) }

  var contentLength: Int64? { nil }

  func readNext(maxLength: Int) async throws -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func invalidate() async {}
}

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

final class DemuxSessionTests: XCTestCase {
  // ── On demand ───────────────────────────────────────

  func testOpensAndListsTracks() async throws {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    XCTAssertEqual(tracks.count, 5)
    XCTAssertEqual(tracks.filter { $0.kind == .video }.count, 1)
    XCTAssertEqual(tracks.filter { $0.kind == .audio }.count, 2)
    XCTAssertEqual(tracks.filter { $0.kind == .subtitle }.count, 2)
  }

  func testTracksCarryDescriptions() async throws {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    XCTAssertEqual(video.video?.width, 320)
    XCTAssertEqual(video.video?.height, 240)
    XCTAssertNil(video.audio)

    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    XCTAssertNotNil(audio.audio)
    XCTAssertNil(audio.video)
    XCTAssertEqual(audio.language, "eng")
  }

  func testForcedFlagSurvivesEndToEnd() async throws {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let subtitles = await session.tracks.filter { $0.kind == .subtitle }
    XCTAssertEqual(subtitles.count, 2)
    XCTAssertFalse(subtitles[0].isForced)
    XCTAssertTrue(subtitles[1].isForced)
  }

  func testSeekableFileReportsFiniteDuration() async throws {
    let source = try UmbelFileSource(url: Fixture.url("moov_at_end.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let duration = await session.duration
    XCTAssertTrue(duration.isValid)
    XCTAssertFalse(duration.isIndefinite)
    XCTAssertEqual(duration.seconds, 2.0, accuracy: 0.3)
    let seekable = await session.isSeekable
    XCTAssertTrue(seekable)
  }

  func testReadsPacketsUntilNil() async throws {
    let source = try UmbelFileSource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    var count = 0
    var seen = Set<UmbelTrack.ID>()
    while let packet = try await session.nextPacket() {
      seen.insert(packet.trackID)
      count += 1
      if count > 1000 { XCTFail("the end was not reported"); break }
    }
    XCTAssertGreaterThan(count, 0)
    XCTAssertFalse(seen.isEmpty)
  }

  func testSeekLandsAtOrBeforeTarget() async throws {
    let source = try UmbelFileSource(url: Fixture.url("moov_at_end.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    try await session.seek(to: CMTime(seconds: 1.0, preferredTimescale: 600))
    let read = try await session.nextPacket()
    let packet = try XCTUnwrap(read)
    XCTAssertTrue(packet.presentationTime.isValid)
    XCTAssertLessThanOrEqual(packet.presentationTime.seconds, 1.01,
                             "a container seek lands on the keyframe before the target")
  }

  // ── Streaming (live): the same core, special in three places only ──

  /// The duration comes from **what the container declares**, not from
  /// whether it can seek — two things to keep apart. MP4's index states the
  /// duration, readable in order too: it cannot seek, but its duration is
  /// known.
  func testStreamingSourceOverDeclaredDurationStillReportsIt() async throws {
    let source = try SequentialOnlySource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let duration = await session.duration
    XCTAssertTrue(duration.isValid)
    XCTAssertFalse(duration.isIndefinite, "a duration the container declares is not reported unknown")
    let seekable = await session.isSeekable
    XCTAssertFalse(seekable, "but it still cannot seek")
  }

  /// Live as it really is: no duration field in the container, and no
  /// seeking to the end to estimate one.
  func testLiveLikeStreamReportsIndefiniteDuration() async throws {
    let source = try SequentialOnlySource(url: Fixture.url("live_like.ts"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let duration = await session.duration
    XCTAssertTrue(duration.isIndefinite, "an unknown duration is indefinite, neither nil nor zero")
  }

  func testLiveLikeStreamReadsThroughSameCodePath() async throws {
    let source = try SequentialOnlySource(url: Fixture.url("live_like.ts"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    var count = 0
    while (try await session.nextPacket()) != nil {
      count += 1
      if count > 2000 { break }
    }
    XCTAssertGreaterThan(count, 0, "a live container goes through the same reading of packets")
  }

  func testStreamingSourceIsNotSeekable() async throws {
    let source = try SequentialOnlySource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }
    let seekable = await session.isSeekable
    XCTAssertFalse(seekable)
  }

  func testStreamingSourceSeekThrowsSeekUnsupported() async throws {
    let source = try SequentialOnlySource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    do {
      try await session.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
      XCTFail("seeking a streaming source throws seekUnsupported")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .seekUnsupported)
    }
  }

  func testStreamingSourceReadsThroughSameCodePath() async throws {
    let source = try SequentialOnlySource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    var count = 0
    while (try await session.nextPacket()) != nil {
      count += 1
      if count > 1000 { break }
    }
    XCTAssertGreaterThan(count, 0, "the live path goes through the same reading of packets")
  }

  // ── Errors ──────────────────────────────────────────

  func testTruncatedFileThrowsStructuredError() async throws {
    let source = try UmbelFileSource(url: Fixture.url("truncated.mp4"))
    let session = DemuxSession(source: source)
    do {
      try await session.open()
      await session.close()
      XCTFail("a truncated file does not open")
    } catch let error as UmbelError {
      // The case is checked, not its payload: the payload is diagnostic text
      // for people, and pinning it in tests would mean changing tests with
      // every rewording, for no gain.
      guard case .unsupportedContainer = error else {
        return XCTFail("expected unsupportedContainer, got \(error)")
      }
      XCTAssertFalse(error.isRetryable)
    } catch {
      XCTFail("expected UmbelError, got \(error)")
    }
  }

  func testNextPacketBeforeOpenThrows() async throws {
    let source = try UmbelFileSource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    do {
      _ = try await session.nextPacket()
      XCTFail("reading a packet before opening throws")
    } catch {
      // As expected
    }
  }

  func testCloseIsIdempotent() async throws {
    let source = try UmbelFileSource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    await session.close()
    await session.close()
  }

  func testTracksAreEmptyBeforeOpen() async throws {
    let source = try UmbelFileSource(url: Fixture.url("short.mp4"))
    let session = DemuxSession(source: source)
    let tracks = await session.tracks
    XCTAssertTrue(tracks.isEmpty)
  }
}

/// A file read at offsets, each read's offset noted: what a network source
/// sees as its requests.
private actor OffsetRecordingSource: UmbelRandomAccessSource {
  private let file: UmbelFileSource
  private(set) var offsets: [Int64] = []

  init(url: URL) throws { file = try UmbelFileSource(url: url) }

  var contentLength: Int64? { get async { await file.contentLength } }
  func invalidate() async {}
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    offsets.append(offset)
    return try await file.read(offset: offset, maxLength: maxLength)
  }
}

/// Opening reads on from the bytes looked at to tell a playlist: a network
/// source keeps one connection going as long as reading carries on where it
/// stopped, and went back to the start opened another — one more round trip
/// before anything played.
final class DemuxOpeningReadTests: XCTestCase {
  func testReadingCarriesOnFromTheBytesLookedAt() async throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("sync_check.mp4")
    let source = try OffsetRecordingSource(url: url)
    let demux = DemuxSession(source: source)
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let offsets = await source.offsets
    XCTAssertEqual(offsets.first, 0, "looked at first")
    XCTAssertEqual(offsets.dropFirst().first, 64, "then on from there, not from 0 again")
    let tracks = await demux.tracks
    XCTAssertEqual(tracks.count, 2, "opened all the same")
  }
}
