import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

/// hls/ad.m3u8: 6 s of the film, a 4 s ad whose timestamps start over and
/// whose picture and sound are encoded otherwise, then 6 s more of the film,
/// whose timestamps run on from before the ad.
final class PlaylistDemuxerTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls").appendingPathComponent(name)
  }

  private func opened(
    _ name: String, server: FixtureServer = FixtureServer()
  ) async throws -> PlaylistDemuxer {
    let url = fixture(name)
    let playlist = try HLSMediaPlaylist.parse(String(contentsOf: url, encoding: .utf8), base: url)
    let demuxer = PlaylistDemuxer(
      playlist: playlist, open: { server.source($0) },
      configuration: FFmpegDemuxerConfiguration(
        analyzeDurationMicroseconds: 1_000_000, formatName: "mpegts"))
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    return demuxer
  }

  private func drain(_ demuxer: PlaylistDemuxer) async throws -> [DemuxPacket] {
    var packets: [DemuxPacket] = []
    while let packet = try await demuxer.nextPacket() { packets.append(packet) }
    return packets
  }

  private func untagged(_ names: [String]) async throws -> PlaylistDemuxer {
    let text = (["#EXTM3U", "#EXT-X-TARGETDURATION:2"]
      + names.flatMap { ["#EXTINF:2.0,", $0] } + ["#EXT-X-ENDLIST"]).joined(separator: "\n")
    let playlist = try HLSMediaPlaylist.parse(text, base: fixture("untagged.m3u8"))
    let server = FixtureServer()
    let demuxer = PlaylistDemuxer(playlist: playlist, open: { server.source($0) },
      configuration: FFmpegDemuxerConfiguration(formatName: "mpegts"))
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    return demuxer
  }

  func testOmittedSegmentsWithoutTagsDoNotBecomePresentationGaps() async throws {
    let demuxer = try await untagged(["main0", "main2", "main3", "main5"])
    let tracks = await demuxer.tracks
    let packets = try await drain(demuxer)
    for track in tracks where track.kind == .audio || track.kind == .video {
      let times = packets.filter { $0.trackID == track.id }.map(\.presentationTime.seconds).sorted()
      XCTAssertEqual(times.last ?? -1, 7.96, accuracy: 0.1)
      XCTAssertLessThan(zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.1)
    }
    // Seeking discards the prior recovered offsets and anchors to the playlist.
    try await demuxer.seek(to: CMTime(seconds: 6.5, preferredTimescale: 600))
    let landed = try await firstVideo(demuxer)
    XCTAssertEqual(landed?.presentationTime.seconds ?? -1, 6, accuracy: 0.05)
  }

  func testUntaggedBackwardResetPreservesBothTracks() async throws {
    let demuxer = try await untagged(["main0", "main1", "main0", "main1"])
    let tracks = await demuxer.tracks
    let packets = try await drain(demuxer)
    for track in tracks where track.kind == .audio || track.kind == .video {
      let times = packets.filter { $0.trackID == track.id }.map(\.presentationTime.seconds).sorted()
      XCTAssertEqual(times.last ?? -1, 7.96, accuracy: 0.1)
      XCTAssertGreaterThan(zip(times, times.dropFirst()).map { $1 - $0 }.min() ?? -1, 0)
      XCTAssertLessThan(zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.1)
    }
  }

  private func videoID(of demuxer: PlaylistDemuxer) async throws -> UmbelTrack.ID {
    let tracks = await demuxer.tracks
    return try XCTUnwrap(tracks.first { $0.kind == .video }?.id)
  }

  private func videoTimes(_ packets: [DemuxPacket], _ id: UmbelTrack.ID) -> [Double] {
    packets.filter { $0.trackID == id }.map(\.presentationTime.seconds).sorted()
  }

  private func firstVideo(_ demuxer: PlaylistDemuxer) async throws -> DemuxPacket? {
    let id = try await videoID(of: demuxer)
    while let packet = try await demuxer.nextPacket() {
      if packet.trackID == id { return packet }
    }
    return nil
  }

  /// Encrypted, the first three segments come out as their clear originals.
  func testAnEncryptedPlaylistDemuxesLikeTheClearOne() async throws {
    let encrypted = try await opened("aes/index.m3u8")
    let clear = try await opened("tagged.m3u8")
    let id = try await videoID(of: encrypted)
    let decrypted = try await drain(encrypted).filter { $0.trackID == id }.map(\.data)
    let originals = try await drain(clear).filter { $0.trackID == id }.map(\.data)
    XCTAssertGreaterThan(decrypted.count, 150)
    XCTAssertEqual(decrypted, Array(originals.prefix(decrypted.count)))
  }

  func testTheSequenceNumberIsTheIVWhenNoneIsNamed() async throws {
    let demuxer = try await opened("aes_seq/index.m3u8")
    let id = try await videoID(of: demuxer)
    let video = videoTimes(try await drain(demuxer), id)
    XCTAssertEqual(video.last ?? -1, 5.96, accuracy: 0.1)
  }

  /// A key that is a web page: its segment is passed over like a lost one.
  func testAKeyThatIsNotSixteenBytesLosesItsSegment() async throws {
    let demuxer = try await opened("aes_badkey/index.m3u8")
    let id = try await videoID(of: demuxer)
    let video = videoTimes(try await drain(demuxer), id)
    XCTAssertFalse(video.contains { (2.1..<3.9).contains($0) })
    XCTAssertEqual(video.last ?? -1, 5.96, accuracy: 0.1)
  }

  /// Segments served as pictures: a PNG header in front of each. They play
  /// as the film they carry, from its first keyframe, with no hole.
  func testDisguisedSegmentsPlay() async throws {
    let demuxer = try await opened("disguised/index.m3u8")
    let id = try await videoID(of: demuxer)
    let packets = try await drain(demuxer).filter { $0.trackID == id }
    XCTAssertEqual(packets.first?.isKeyframe, true)
    let video = packets.map(\.presentationTime.seconds).sorted()
    XCTAssertEqual(video.first ?? -1, 0, accuracy: 0.05)
    XCTAssertEqual(video.last ?? -1, 5.96, accuracy: 0.1)
    let gaps = zip(video, video.dropFirst()).map { $1 - $0 }
    XCTAssertLessThan(gaps.max() ?? 1, 0.1)
  }

  func testFragmentedMP4Plays() async throws {
    let demuxer = try await opened("fmp4/index.m3u8")
    let tracks = await demuxer.tracks
    XCTAssertEqual(tracks.map(\.kind.rawValue).sorted(), ["audio", "video"])
    let duration = await demuxer.duration
    XCTAssertEqual(duration.seconds, 12, accuracy: 0.1)
    let id = try await videoID(of: demuxer)
    let video = videoTimes(try await drain(demuxer), id)
    XCTAssertEqual(video.first ?? -1, 0, accuracy: 0.05)
    XCTAssertEqual(video.last ?? -1, 11.96, accuracy: 0.1)
    XCTAssertLessThan(zip(video, video.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.1)

    try await demuxer.seek(to: CMTime(seconds: 7, preferredTimescale: 600))
    let landed = try await firstVideo(demuxer)
    XCTAssertEqual(landed?.presentationTime.seconds ?? -1, 6, accuracy: 0.05)
  }

  /// A new initialisation segment midway — another encoding — starts a run:
  /// the rest decodes with its own parameters, on from where the first
  /// part ended.
  func testANewInitialisationSegmentStartsARun() async throws {
    let demuxer = try await opened("fmp4/remap.m3u8")
    let id = try await videoID(of: demuxer)
    let packets = try await drain(demuxer).filter { $0.trackID == id }
    let first = try XCTUnwrap(packets.first?.decoderParameters)
    let last = try XCTUnwrap(packets.last?.decoderParameters)
    XCTAssertFalse(last.isSameFormat(as: first))
    let video = packets.map(\.presentationTime.seconds).sorted()
    XCTAssertEqual(video.last ?? -1, 11.96, accuracy: 0.1)
    XCTAssertLessThan(zip(video, video.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.1)
  }

  func testTracksAndDurationComeFromTheFirstRunAndThePlaylist() async throws {
    let demuxer = try await opened("ad.m3u8")
    let tracks = await demuxer.tracks
    XCTAssertEqual(tracks.map(\.kind.rawValue).sorted(), ["audio", "video"])
    let duration = await demuxer.duration
    XCTAssertEqual(duration.seconds, 16, accuracy: 0.1)
  }

  /// The ad starts its timestamps over and the film runs on past it; on the
  /// timeline they follow each other with no step back and no gap.
  func testTheTimelineRunsStraightThroughTheAd() async throws {
    let demuxer = try await opened("ad.m3u8")
    let id = try await videoID(of: demuxer)
    let video = videoTimes(try await drain(demuxer), id)
    XCTAssertEqual(video.first ?? -1, 0, accuracy: 0.05)
    XCTAssertEqual(video.last ?? -1, 15.96, accuracy: 0.1)
    let gaps = zip(video, video.dropFirst()).map { $1 - $0 }
    XCTAssertLessThan(gaps.max() ?? 1, 0.1, "no hole where the ad went in")
  }

  func testTheAdAndTheFilmAfterItCarryTheirOwnParameters() async throws {
    let demuxer = try await opened("ad.m3u8")
    let id = try await videoID(of: demuxer)
    let packets = try await drain(demuxer).filter { $0.trackID == id }
    let film = try XCTUnwrap(packets.first { $0.presentationTime.seconds < 5 }?.decoderParameters)
    let ad = try XCTUnwrap(
      packets.first { (6.5...9.5).contains($0.presentationTime.seconds) }?.decoderParameters)
    let after = try XCTUnwrap(packets.last?.decoderParameters)
    XCTAssertFalse(ad.isSameFormat(as: film))
    XCTAssertTrue(after.isSameFormat(as: film))
  }

  /// Tags with nothing behind them change nothing: the same parameters
  /// object throughout, so no decoder is made again.
  func testTagsWithoutABreakKeepOneParametersObject() async throws {
    let demuxer = try await opened("tagged.m3u8")
    let packets = try await drain(demuxer)
    let objects = Set(packets.compactMap(\.decoderParameters).map(ObjectIdentifier.init))
    XCTAssertEqual(objects.count, 2, "one for picture, one for sound")
    let id = try await videoID(of: demuxer)
    let video = videoTimes(packets, id)
    let gaps = zip(video, video.dropFirst()).map { $1 - $0 }
    XCTAssertLessThan(gaps.max() ?? 1, 0.1)
    XCTAssertGreaterThan(gaps.min() ?? 0, 0.001, "no step back at a tag")
  }

  /// After the ad the progress bar and the film part ways by its length;
  /// a seek lands where the bar says.
  func testASeekAfterTheAdLandsWhereTheBarSays() async throws {
    let demuxer = try await opened("ad.m3u8")
    try await demuxer.seek(to: CMTime(seconds: 12.5, preferredTimescale: 600))
    let landed = try await firstVideo(demuxer)
    XCTAssertEqual(landed?.isKeyframe, true)
    XCTAssertEqual(landed?.presentationTime.seconds ?? -1, 12, accuracy: 0.05,
                   "the segment the target is in")
  }

  /// A segment need not start on a keyframe: here the second is the tail of
  /// one, cut at a transport packet mid-picture-group. A seek into it backs
  /// off to the segment before, so decoding starts on a keyframe before the
  /// target rather than on the next one after it.
  func testASeekIntoASegmentWithoutAKeyframeBacksOffOne() async throws {
    let text = [
      "#EXTM3U", "#EXT-X-TARGETDURATION:2",
      "#EXTINF:2.0,", "main0",
      "#EXT-X-BYTERANGE:58092@34592", "#EXTINF:1.2,", "main1",
      "#EXTINF:2.0,", "main2", "#EXT-X-ENDLIST",
    ].joined(separator: "\n")
    let playlist = try HLSMediaPlaylist.parse(text, base: fixture("cut.m3u8"))
    let server = FixtureServer()
    let demuxer = PlaylistDemuxer(
      playlist: playlist, open: { server.source($0) },
      configuration: FFmpegDemuxerConfiguration(
        analyzeDurationMicroseconds: 1_000_000, formatName: "mpegts"))
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    try await demuxer.seek(to: CMTime(seconds: 2.1, preferredTimescale: 600))
    let id = try await videoID(of: demuxer)
    var keyframe: DemuxPacket?
    while keyframe == nil, let packet = try await demuxer.nextPacket() {
      if packet.trackID == id, packet.isKeyframe { keyframe = packet }
    }
    XCTAssertLessThanOrEqual(keyframe?.presentationTime.seconds ?? 99, 2.1,
                             "a keyframe at or before the target")
  }

  func testSeeksPastTheEndOrBeforeTheStartAreHeldToIt() async throws {
    let demuxer = try await opened("ad.m3u8")
    try await demuxer.seek(to: CMTime(seconds: 99, preferredTimescale: 600))
    let late = try await firstVideo(demuxer)
    XCTAssertEqual(late?.presentationTime.seconds ?? -1, 14, accuracy: 0.1, "the last segment")
    try await demuxer.seek(to: CMTime(seconds: -5, preferredTimescale: 600))
    let early = try await firstVideo(demuxer)
    XCTAssertEqual(early?.presentationTime.seconds ?? -1, 0, accuracy: 0.1)
  }

  /// A segment the server lost is passed over: what follows lands at its own
  /// place on the timeline, leaving a hole.
  func testALostSegmentIsPassedOver() async throws {
    let demuxer = try await opened("ad.m3u8", server: FixtureServer(failing: ["main1"]))
    let id = try await videoID(of: demuxer)
    let video = videoTimes(try await drain(demuxer), id)
    XCTAssertFalse(video.contains { (2.1..<3.9).contains($0) }, "main1's two seconds are missing")
    XCTAssertTrue(video.contains { (4.0..<4.1).contains($0) }, "main2 is where the playlist puts it")
    XCTAssertEqual(video.last ?? -1, 15.96, accuracy: 0.1)
  }

  func testThreeLostInARowStopPlayback() async throws {
    let server = FixtureServer(failing: ["main1", "main2", "ad0.ts"])
    let demuxer = try await opened("ad.m3u8", server: server)
    do {
      _ = try await drain(demuxer)
      XCTFail("three segments in a row cannot be had")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
  }

  /// A server that answers a lost segment with a web page and 200.
  func testASegmentThatIsAWebPageIsPassedOver() async throws {
    let demuxer = try await opened("soft404.m3u8")
    let id = try await videoID(of: demuxer)
    let video = videoTimes(try await drain(demuxer), id)
    XCTAssertEqual(video.last ?? -1, 11.96, accuracy: 0.1, "played to the end")
    XCTAssertTrue(video.contains { $0 >= 6 && $0 < 6.1 }, "main3 where the playlist puts it")
  }
}
