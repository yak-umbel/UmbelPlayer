import CoreMedia
import XCTest
@testable import UmbelCore

private final class StoppedHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Subtitles through a whole session: selection, seeking, stopping.
final class SubtitlePlaybackTests: XCTestCase {
  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }

  private func session(_ fixture: String) async throws -> PlaybackSession {
    let host = StoppedHostTime()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixtureURL(fixture)),
      audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    return session
  }

  private func waitForCues(
    _ expected: [String], in session: PlaybackSession,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    var seen: [String] = []
    for _ in 0..<100 {
      seen = await session.currentSubtitleCues.map(\.plainText)
      if seen == expected { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("expected \(expected), still showing \(seen)", file: file, line: line)
  }

  private func subtitleTrack(
    _ session: PlaybackSession, where matches: (UmbelTrack) -> Bool
  ) async throws -> UmbelTrack {
    let tracks = await session.tracks
    return try XCTUnwrap(tracks.first { $0.kind == .subtitle && matches($0) })
  }

  // Seek targets below sit just after a cue starts. Landing mid-line in a
  // later cluster than the line started in is covered separately, with
  // clustered_subs.mkv.

  /// A seek empties what was decoded and refills from the target, even while
  /// paused: the frame shown after a paused seek needs its subtitle too.
  func testSeekShowsTheCueAtTheTarget() async throws {
    let session = try await session("multi_track.mkv")
    addTeardownBlock { await session.stop() }
    let english = try await subtitleTrack(session) { $0.language == "eng" }
    try await session.selectSubtitleTrack(english.id)

    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    try await waitForCues(["second line"], in: session)

    try await session.seek(to: CMTime(seconds: 0.3, preferredTimescale: 600))
    try await waitForCues(["first line"], in: session)

    // Back and forth: without emptying on each seek, the same line is decoded
    // again from the new position and shows twice.
    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    try await waitForCues(["second line"], in: session)
  }

  /// Styles reach the cue: the ASS track's second event uses a top-aligned
  /// style, the first carries an italic override.
  func testStyledTrackKeepsAlignmentAndOverrides() async throws {
    let session = try await session("styled_subs.mkv")
    addTeardownBlock { await session.stop() }
    let styled = try await subtitleTrack(session) { $0.codecName == "ass" }
    try await session.selectSubtitleTrack(styled.id)

    try await session.seek(to: CMTime(seconds: 0.6, preferredTimescale: 600))
    try await waitForCues(["plain italic red"], in: session)
    let firstCues = await session.currentSubtitleCues
    let first = try XCTUnwrap(firstCues.first)
    XCTAssertEqual(first.runs.map(\.isItalic), [false, true, false, false])
    XCTAssertEqual(first.alignment, .bottomCenter)

    try await session.seek(to: CMTime(seconds: 2.2, preferredTimescale: 600))
    try await waitForCues(["sign on top"], in: session)
    let signCues = await session.currentSubtitleCues
    let sign = try XCTUnwrap(signCues.first)
    XCTAssertEqual(sign.alignment, .topCenter)
    XCTAssertTrue(sign.runs[0].isBold)
  }

  /// The index answers where the last subtitle before a time started — the
  /// point a seek reads from so that line is not missed.
  ///
  /// MP4 has its index from the start. A Matroska file keeps its index at the
  /// end, and FFmpeg reads it only on the first seek: before that the lookup
  /// finds nothing, after it the subtitle entries are there. That is why a
  /// seek looks twice.
  func testIndexGivesTheLatestSubtitleStart() async throws {
    let target = CMTime(seconds: 1.2, preferredTimescale: 600)
    let mp4 = DemuxSession(source: try UmbelFileSource(url: fixtureURL("movtext_subs.mp4")))
    try await mp4.open()
    let start = await mp4.indexedTime(of: UmbelTrack.ID(rawValue: 2), atOrBefore: target)
    XCTAssertEqual(try XCTUnwrap(start).seconds, 0.5, accuracy: 0.001)
    await mp4.close()

    let mkv = DemuxSession(source: try UmbelFileSource(url: fixtureURL("multi_track.mkv")))
    try await mkv.open()
    let english = UmbelTrack.ID(rawValue: 3)
    let beforeSeeking = await mkv.indexedTime(of: english, atOrBefore: target)
    XCTAssertNil(beforeSeeking, "the Matroska index is not read until the first seek")
    try await mkv.seek(to: target)
    let afterSeeking = await mkv.indexedTime(of: english, atOrBefore: target)
    XCTAssertEqual(try XCTUnwrap(afterSeeking).seconds, 1.0, accuracy: 0.001)
    await mkv.close()
  }

  /// The very first seek in a Matroska file lands mid-line and still shows
  /// it. The index is not loaded yet when that seek starts; looking only
  /// once, the line was missed until the next — on the first seek of every
  /// file, which is the one a viewer makes first.
  ///
  /// FFmpeg seeks a Matroska file to the start of the cluster holding the
  /// key frame, and passes on every subtitle in that cluster; a line is
  /// missed only when it started in an earlier cluster. The fixture starts
  /// a cluster at every key frame (every 0.48 s), and its one line runs
  /// 0.5–3.5 s, so a seek to 2 s reads from 1.92 s — past the line's start.
  func testFirstSeekInAMatroskaFileReadsTheLineShowing() async throws {
    let session = try await session("clustered_subs.mkv")
    addTeardownBlock { await session.stop() }
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 2))
    try await session.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
    try await waitForCues(["long line across clusters"], in: session)
  }

  /// Prerolling reaches back at most ten seconds: an index entry further
  /// back says a line started long ago, not that it still shows.
  func testPrerollReachesBackTenSecondsAtMost() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("movtext_subs.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let controller = SubtitleController(demux: demux)
    try await controller.selectManually(UmbelTrack.ID(rawValue: 2))

    let near = await controller.prerollStart(before: CMTime(seconds: 1.2, preferredTimescale: 600))
    XCTAssertEqual(try XCTUnwrap(near).seconds, 0.5, accuracy: 0.001)
    let far = await controller.prerollStart(before: CMTime(seconds: 10.6, preferredTimescale: 600))
    XCTAssertNil(far, "10.1 s back is past the limit")

    try await controller.selectManually(nil)
    let off = await controller.prerollStart(before: CMTime(seconds: 1.2, preferredTimescale: 600))
    XCTAssertNil(off, "no subtitle selected, nothing to preroll for")
    await controller.close()
  }

  /// Seeking into the middle of a cue, past a key frame that comes after the
  /// cue started, still shows it — and reading from earlier does not move the
  /// target.
  ///
  /// MP4 seeks each track by its own index, so here the cue would be read
  /// even without the preroll; what this pins is that reading from the cue's
  /// start leaves the seek exact. The cue runs 0.5–1.5 s; key frames fall
  /// every 0.48 s.
  func testSeekIntoACueShowsItAndStaysExact() async throws {
    let session = try await session("movtext_subs.mp4")
    addTeardownBlock { await session.stop() }
    let movText = try await subtitleTrack(session) { $0.codecName == "mov_text" }
    try await session.selectSubtitleTrack(movText.id)

    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    try await waitForCues(["mov text line"], in: session)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 1.2, accuracy: 0.05, "reading earlier does not move the target")
  }

  func testStopClearsSubtitles() async throws {
    let session = try await session("multi_track.mkv")
    let english = try await subtitleTrack(session) { $0.language == "eng" }
    try await session.selectSubtitleTrack(english.id)
    try await session.seek(to: CMTime(seconds: 0.3, preferredTimescale: 600))
    try await waitForCues(["first line"], in: session)

    await session.stop()
    let after = await session.currentSubtitleCues
    XCTAssertTrue(after.isEmpty)
  }
}
