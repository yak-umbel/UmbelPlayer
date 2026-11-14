import XCTest
@testable import UmbelFFmpegSupport

enum FixtureLocator {
  static func url(for name: String) -> URL {
    // Tests/UmbelFFmpegSupportTests/Demux/ → three levels up to Tests/
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }
}

/// A fixture reader that reads in order, able to stand in for a stream that
/// cannot seek.
private actor FixtureReader {
  private let data: Data
  private var position: Int = 0
  let length: Int64?

  init(named name: String) throws {
    self.data = try Data(contentsOf: FixtureLocator.url(for: name))
    self.length = Int64(data.count)
  }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) throws {
    position = min(Int(offset), data.count)
  }
}

private func fileCallbacks(
  named name: String,
  canSeek: Bool = true
) throws -> FFmpegIOCallbacks {
  let reader = try FixtureReader(named: name)
  return FFmpegIOCallbacks(
    read: { maxLength in await reader.read(maxLength: maxLength) },
    seek: { offset in try await reader.seek(to: offset) },
    totalLength: { await reader.length },
    canSeek: canSeek
  )
}

final class FFmpegDemuxerTests: XCTestCase {
  func testOriginalPacketInitializerRetainsItsFunctionType() {
    let make: (Int32, Data, Int64, Int64, Int64, Int32, Int32, Bool) -> FFmpegPacket = FFmpegPacket.init
    let packet = make(0, Data(), 7, 5, 2, 1, 90_000, false)
    XCTAssertEqual(packet.pts, 7)
  }

  func testTransportPacketsRetainTheirLogicalBytePositions() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "hls/main0", canSeek: false),
      configuration: FFmpegDemuxerConfiguration(formatName: "mpegts"))
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    var positions: [Int64] = []
    while let packet = try await demuxer.readPacket() {
      if let position = packet.bytePosition { positions.append(position) }
    }
    XCTAssertGreaterThan(positions.count, 50)
    XCTAssertTrue(positions.allSatisfy { $0 >= 0 && $0 % 188 == 0 })
    XCTAssertTrue(positions.contains(564), "first video PES starts after the TS headers")
  }

  /// A run of a playlist is known to be a transport stream; saying so spares
  /// probing, and a probe cannot talk it into being something else.
  func testTheFormatCanBeNamed() async throws {
    let named = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "rate_change.ts", canSeek: false),
      configuration: FFmpegDemuxerConfiguration(formatName: "mpegts"))
    try await named.open()
    let streams = await named.streams()
    XCTAssertEqual(streams.count, 1)
    await named.close()

    let wrong = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "rate_change.ts", canSeek: false),
      configuration: FFmpegDemuxerConfiguration(formatName: "matroska"))
    do {
      try await wrong.open()
      XCTFail("a transport stream read as Matroska")
    } catch {}
    await wrong.close()
  }

  func testOpensMultiTrackFileAndListsStreams() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "multi_track.mkv"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    XCTAssertEqual(streams.count, 5)
    XCTAssertEqual(streams.filter { $0.mediaType == .video }.count, 1)
    XCTAssertEqual(streams.filter { $0.mediaType == .audio }.count, 2)
    XCTAssertEqual(streams.filter { $0.mediaType == .subtitle }.count, 2)
  }

  func testVideoStreamCarriesDimensions() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "multi_track.mkv"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    XCTAssertEqual(video.width, 320)
    XCTAssertEqual(video.height, 240)
    XCTAssertEqual(video.codecName, "mpeg4")
  }

  func testAudioStreamsCarryLanguageAndDisposition() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "multi_track.mkv"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let audio = await demuxer.streams().filter { $0.mediaType == .audio }
    XCTAssertEqual(audio.count, 2)
    XCTAssertEqual(audio.first?.language, "eng")
    XCTAssertEqual(audio.first?.title, "stereo")
    XCTAssertTrue(audio.first?.isDefault ?? false)
  }

  func testForcedSubtitleDispositionIsRead() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "multi_track.mkv"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let subtitles = await demuxer.streams().filter { $0.mediaType == .subtitle }
    XCTAssertEqual(subtitles.count, 2)
    XCTAssertFalse(subtitles[0].isForced)
    XCTAssertTrue(subtitles[1].isForced, "the second subtitle track in the fixture is marked forced")
  }

  func testOpensFileWithIndexAtEnd() async throws {
    // An index at the end means probing has to be able to read back.
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "moov_at_end.mp4"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    XCTAssertEqual(streams.count, 2)
  }

  func testReadsPacketsUntilEnd() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "short.mp4"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    var count = 0
    while let packet = try await demuxer.readPacket() {
      XCTAssertFalse(packet.data.isEmpty)
      XCTAssertGreaterThan(packet.timeBaseDen, 0)
      count += 1
      if count > 1000 { XCTFail("too many packets; the end may not have been reported"); break }
    }
    XCTAssertGreaterThan(count, 0)
  }

  func testFirstPacketIsKeyframe() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "short.mp4"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let packet = try await demuxer.readPacket()
    let first = try XCTUnwrap(packet)
    XCTAssertTrue(first.isKeyframe)
  }

  func testDurationIsReportedForSeekableFile() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "moov_at_end.mp4"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let duration = await demuxer.durationTicks()
    XCTAssertNotNil(duration)
  }

  func testSeekMovesPlayhead() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "moov_at_end.mp4"), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    _ = try await demuxer.readPacket()
    try await demuxer.seek(toSeconds: 1.0)
    let read = try await demuxer.readPacket()
    let packet = try XCTUnwrap(read)
    XCTAssertNotEqual(packet.pts, FFmpegPacket.noTimestamp)
  }

  func testNonSeekableSourceRejectsSeek() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "short.mp4", canSeek: false), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    do {
      try await demuxer.seek(toSeconds: 0.5)
      XCTFail("seeking a source that cannot seek throws")
    } catch {
      // As expected
    }
  }

  func testNonSeekableSourceStillReadsToEnd() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "short.mp4", canSeek: false), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    var count = 0
    while (try await demuxer.readPacket()) != nil {
      count += 1
      if count > 1000 { break }
    }
    XCTAssertGreaterThan(count, 0, "a source that cannot seek still reads to the end")
  }

  func testTruncatedFileFailsToOpen() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "truncated.mp4"), configuration: .init())
    do {
      try await demuxer.open()
      await demuxer.close()
      XCTFail("a truncated file does not open")
    } catch {
      // As expected: an error, not a crash
    }
  }

  func testInterruptStopsOpen() async throws {
    let demuxer = FFmpegDemuxer(
      callbacks: try fileCallbacks(named: "multi_track.mkv"), configuration: .init())
    demuxer.requestInterrupt()
    do {
      try await demuxer.open()
      await demuxer.close()
      XCTFail("opening fails once an interrupt is requested")
    } catch {
      // As expected
    }
  }
}
