import CoreMedia
import XCTest
@testable import UmbelCore

private final class ManualHost: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    seconds += delta
    lock.unlock()
  }
}

/// A playlist given as a source plays like a file: recognised by its first
/// bytes, whatever its address says.
final class PlaylistPlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls").appendingPathComponent(name)
  }

  func testADemuxSessionRecognisesAPlaylist() async throws {
    let demux = DemuxSession(source: FixtureServer().source(fixture("ad.m3u8")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let duration = await demux.duration
    XCTAssertEqual(duration.seconds, 16, accuracy: 0.1)
    let seekable = await demux.isSeekable
    XCTAssertTrue(seekable)
  }

  func testAPlaylistFromASourceThatCannotOpenItsSegmentsIsRefused() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("ad.m3u8")))
    do {
      try await demux.open()
      XCTFail("a file source cannot open the segments")
    } catch let error as UmbelError {
      guard case .unsupportedContainer = error else { return XCTFail("\(error)") }
    }
  }

  /// The whole of it, the ad and its change of format included: the sound
  /// reaches the output in the format it was prepared in, and the clock
  /// ends on the playlist's end.
  func testThePlaylistWithAnAdPlaysToTheEnd() async throws {
    try await playToTheEnd("ad.m3u8")
  }

  /// An ad with no sound: the picture carries on, and so does the clock.
  func testAnAdWithNoSoundDoesNotHoldPlaybackUp() async throws {
    try await playToTheEnd("silent_ad.m3u8")
  }

  /// Over the network, with the site's headers: the playlist and every
  /// segment ask with them.
  func testTheHeadersReachEverySegment() async throws {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/hls/ad.m3u8")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let demux = DemuxSession(source: source)
    try await demux.open()
    addTeardownBlock { await demux.close() }
    var count = 0
    while try await demux.nextPacket() != nil { count += 1 }
    XCTAssertGreaterThan(count, 100)
  }

  /// The playlist is fetched once: read on from where recognising it
  /// stopped, not asked for again — on a slow site a request can take
  /// seconds.
  func testThePlaylistIsAskedForOnce() async throws {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/hls/tagged.m3u8")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let demux = DemuxSession(source: source)
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let asked = HeaderStubProtocol.requests.filter { $0 == "GET /hls/tagged.m3u8" }
    XCTAssertEqual(asked.count, 1)
  }

  private func web(_ path: String) -> UmbelHTTPSource {
    UmbelHTTPSource(
      url: URL(string: "https://origin.invalid\(path)")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
  }

  /// A live playlist: fetched again as it grows, played from near its
  /// newest segments with its clock starting at nought. It cannot seek, and
  /// it ends when the playlist says it has.
  func testALivePlaylistPlaysOn() async throws {
    func list(_ sequences: ClosedRange<Int>, ended: Bool = false) -> String {
      var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(sequences.lowerBound)"]
      for sequence in sequences { lines += ["#EXTINF:2,", "/hls/main\(sequence)"] }
      if ended { lines.append("#EXT-X-ENDLIST") }
      return lines.joined(separator: "\n") + "\n"
    }
    // Twice as it first was: a live list is fetched again before playing
    // starts, in case the host's source kept an old one.
    HeaderStubProtocol.publish(
      [list(0...3), list(0...3), list(1...5, ended: true)], at: "/live/index.m3u8")
    let demux = DemuxSession(source: web("/live/index.m3u8"))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let seekable = await demux.isSeekable
    XCTAssertFalse(seekable)
    let duration = await demux.duration
    XCTAssertTrue(duration.isIndefinite)
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video }?.id)
    var times: [Double] = []
    while let packet = try await demux.nextPacket() {
      if packet.trackID == video { times.append(packet.presentationTime.seconds) }
    }
    times.sort()
    // From main1, three target durations back from main3's end, to main5.
    XCTAssertEqual(times.first ?? -1, 0, accuracy: 0.05)
    XCTAssertEqual(times.last ?? -1, 9.96, accuracy: 0.1)
    XCTAssertLessThan(zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.1)
  }

  /// A host's disk cache keeps what it read by address; a live playlist read
  /// through it again is hours old. Playing starts from the list as it is
  /// now, not as it was.
  func testALivePlaylistFromADiskCacheStartsFromTheListAsItIsNow() async throws {
    func list(_ sequences: ClosedRange<Int>) -> String {
      (["#EXTM3U", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(sequences.lowerBound)"]
        + sequences.flatMap { ["#EXTINF:2,", "/hls/main\($0)"] }).joined(separator: "\n") + "\n"
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-cache-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let cache = try UmbelDiskCache(directory: folder, capacity: 1 << 24)
    let address = "https://origin.invalid/live/cached.m3u8"
    func session() -> DemuxSession {
      DemuxSession(source: UmbelDiskCacheSource(wrapping: web("/live/cached.m3u8"), key: address, cache: cache))
    }

    HeaderStubProtocol.publish(list(0...3), at: "/live/cached.m3u8")
    let earlier = session()
    try await earlier.open()
    _ = try await earlier.nextPacket()
    await earlier.close()

    HeaderStubProtocol.publish(list(2...5), at: "/live/cached.m3u8")
    let asked = HeaderStubProtocol.requests.count
    let later = session()
    try await later.open()
    addTeardownBlock { await later.close() }
    _ = try await later.nextPacket()
    let segments = HeaderStubProtocol.requests.dropFirst(asked).filter { $0.hasPrefix("GET /hls/main") }
    XCTAssertEqual(segments.first, "GET /hls/main3", "three target durations back from main5's end")
  }

  /// A live playlist this demuxer cannot play — raw AAC segments — goes to
  /// FFmpeg's reading, and is no more seekable there than here: a seek would
  /// fail playback.
  func testALiveStreamPlayedByTheFallbackCannotSeek() async throws {
    let text = (["#EXTM3U", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:0"]
      + (0..<4).flatMap { ["#EXTINF:2.0,", "/hls/packed/a\($0).aac"] }).joined(separator: "\n")
    HeaderStubProtocol.publish(text, at: "/live/packed.m3u8")
    let demux = DemuxSession(source: web("/live/packed.m3u8"))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let seekable = await demux.isSeekable
    XCTAssertFalse(seekable)
    let duration = await demux.duration
    XCTAssertTrue(duration.isIndefinite)
  }

  /// Closing does not wait out the wait for a live playlist's next segment
  /// — here a whole target duration of ten seconds.
  func testClosingALiveStreamDoesNotWaitForItsNextSegment() async throws {
    let text = (["#EXTM3U", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"]
      + (0..<2).flatMap { ["#EXTINF:2,", "/hls/main\($0)"] }).joined(separator: "\n")
    HeaderStubProtocol.publish(text, at: "/live/still.m3u8")
    let demux = DemuxSession(source: web("/live/still.m3u8"))
    try await demux.open()
    let reading = Task { while try await demux.nextPacket() != nil {} }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let started = Date()
    await demux.close()
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    reading.cancel()
    _ = try? await reading.value
  }

  /// Two variants; the one with more bandwidth is the 16 s one with the ad.
  func testAMasterPlaylistPlaysItsBestVariant() async throws {
    let demux = DemuxSession(source: web("/hls/master.m3u8"))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let duration = await demux.duration
    XCTAssertEqual(duration.seconds, 16, accuracy: 0.1)
  }

  /// Found somewhere else than asked for: its variants' relative addresses
  /// resolve against where it was found.
  func testAMovedMasterResolvesItsVariantsFromWhereItWasFound() async throws {
    let demux = DemuxSession(source: web("/moved-master"))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let duration = await demux.duration
    XCTAssertEqual(duration.seconds, 16, accuracy: 0.1)
  }

  private func kinds(read demux: DemuxSession) async throws -> Set<UmbelTrack.Kind> {
    let tracks = await demux.tracks
    var seen = Set<UmbelTrack.Kind>()
    var count = 0
    while count < 2_000, let packet = try await demux.nextPacket() {
      if let kind = tracks.first(where: { $0.id == packet.trackID })?.kind { seen.insert(kind) }
      count += 1
    }
    return seen
  }

  /// Sound in a playlist of its own: FFmpeg's own playlist reading joins it up.
  func testSeparateAudioPlaysThroughTheFallback() async throws {
    let demux = DemuxSession(source: FixtureServer().source(fixture("alt_audio/master.m3u8")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let seen = try await kinds(read: demux)
    XCTAssertEqual(seen, [.video, .audio])
  }

  /// Handed to FFmpeg's reading, a master with separate sound opens only
  /// the variant played and its sound: not the other variants, not the
  /// other languages.
  func testTheFallbackOpensOnlyWhatIsPlayed() async throws {
    let text = [
      "#EXTM3U",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"en\",DEFAULT=YES,URI=\"/hls/alt_audio/audio.m3u8\"",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"fr\",URI=\"/hls/packed/index.m3u8\"",
      "#EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO=\"aud\"", "/hls/tagged.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=900,AUDIO=\"aud\"", "/hls/alt_audio/video.m3u8",
    ].joined(separator: "\n")
    HeaderStubProtocol.publish(text, at: "/multi/master.m3u8")
    let asked = HeaderStubProtocol.requests.count
    let demux = DemuxSession(source: web("/multi/master.m3u8"))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let seen = try await kinds(read: demux)
    XCTAssertEqual(seen, [.video, .audio])
    let requests = HeaderStubProtocol.requests.dropFirst(asked)
    XCTAssertFalse(requests.contains { $0.contains("/hls/tagged") || $0.contains("/hls/main") })
    XCTAssertFalse(requests.contains { $0.contains("/hls/packed") })
  }

  /// Raw AAC segments are not transport streams: FFmpeg's own reading plays
  /// them. This demuxer gives up on its first run rather than trying each
  /// segment in turn: no segment is asked for twice before the fallback.
  func testPackedAudioPlaysThroughTheFallback() async throws {
    let server = FixtureServer()
    let demux = DemuxSession(source: server.source(fixture("packed/index.m3u8")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let seen = try await kinds(read: demux)
    XCTAssertEqual(seen, [.audio])
    let beforeFallback = server.opened.prefix { $0 != "index.m3u8" }
    XCTAssertFalse(beforeFallback.isEmpty)
    XCTAssertEqual(beforeFallback.count, Set(beforeFallback).count)
  }

  /// Segments that are parts of one file, with sound of its own beside them:
  /// FFmpeg's reading gets each part, not the start of the file each time.
  func testByteRangesPlayThroughTheFallback() async throws {
    let demux = DemuxSession(source: web("/hls/ranges/master.m3u8"))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video }?.id)
    var times: [Double] = []
    while let packet = try await demux.nextPacket() {
      if packet.trackID == video { times.append(packet.presentationTime.seconds) }
    }
    XCTAssertEqual((times.max() ?? 0) - (times.min() ?? 0), 5.9, accuracy: 0.2)
  }

  /// Written in a way this demuxer does not take — fragmented MP4 whose
  /// initialisation segment is encrypted too — the playlist goes to FFmpeg's
  /// own reading, which plays it.
  func testWhatThisDemuxerDoesNotTakeGoesToTheFallback() async throws {
    let demux = DemuxSession(source: FixtureServer().source(fixture("aes_fmp4/index.m3u8")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let seen = try await kinds(read: demux)
    XCTAssertEqual(seen, [.video, .audio])
  }

  /// A playlist from the web names files on this machine: none is opened.
  func testAWebPlaylistCannotOpenLocalFiles() async throws {
    let local = (0..<3).map { fixture("main\($0)").absoluteString }
    let text = (["#EXTM3U", "#EXT-X-TARGETDURATION:2"]
      + local.flatMap { ["#EXTINF:2.0,", $0] } + ["#EXT-X-ENDLIST"]).joined(separator: "\n")
    HeaderStubProtocol.publish(text, at: "/dyn/local.m3u8")
    let demux = DemuxSession(source: web("/dyn/local.m3u8"))
    do {
      try await demux.open()
      while try await demux.nextPacket() != nil {}
      XCTFail("a web playlist played files on this machine")
    } catch {}
    await demux.close()
    let reached = HeaderStubProtocol.requests.filter { $0.contains("/Tests/Fixtures/") }
    XCTAssertEqual(reached, [], "no request for a local file went out")
  }

  /// A web playlist whose variant is another scheme: said as that, not as a
  /// failure worth retrying.
  func testAWebPlaylistNamingAnotherSchemeSaysSo() async throws {
    let text = ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=1000", "RTMP://example.invalid/live/stream"]
      .joined(separator: "\n")
    HeaderStubProtocol.publish(text, at: "/dyn/other-scheme.m3u8")
    let demux = DemuxSession(source: web("/dyn/other-scheme.m3u8"))
    do {
      try await demux.open()
      XCTFail("a web playlist opened another scheme")
    } catch {
      XCTAssertEqual(error as? UmbelError, .unsupportedScheme("rtmp"))
    }
    await demux.close()
  }

  private func playToTheEnd(_ name: String) async throws {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: FixtureServer().source(fixture(name)), audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<800 {
      if await session.phase == .ended { break }
      host.advance(seconds: 0.05)
      await output.advance(bySeconds: 0.05)
      await session.refreshClock()
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 3_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .ended)
    let end = await session.currentTime
    XCTAssertEqual(end.seconds, 16, accuracy: 0.2)
    let mismatched = await output.mismatchedFrameCount
    XCTAssertEqual(mismatched, 0, "the ad's sound reached the output in its prepared format")
    // An output times its sound by the samples it has played: sound missing
    // from a stretch has to have been played as silence, or what came after
    // it played early.
    let played = await output.currentAnchor?.mediaTime.seconds ?? -1
    XCTAssertEqual(played, 16, accuracy: 0.2)
  }
}
