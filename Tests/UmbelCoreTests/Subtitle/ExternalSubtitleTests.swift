import CoreMedia
import XCTest
@testable import UmbelCore

private final class ParkedHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Endless whitespace: a source that would never finish reading.
private struct EndlessSource: UmbelStreamingSource {
  var contentLength: Int64? { get async { nil } }
  func readNext(maxLength: Int) async throws -> Data { Data(repeating: 0x20, count: maxLength) }
  func invalidate() async {}
}

final class ExternalSubtitleTests: XCTestCase {
  private func fixture(_ name: String) throws -> UmbelFileSource {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
    return try UmbelFileSource(url: url)
  }

  /// Six seconds long: the external file's cues reach past five, and a seek
  /// beyond the film's end would be clamped.
  private func loadedSession() async throws -> PlaybackSession {
    let session = PlaybackSession(
      source: try fixture("styled_subs.mkv"),
      audioOutput: VirtualAudioOutput(hostTime: ParkedHost()), hostTime: ParkedHost())
    try await session.load()
    return session
  }

  /// A GBK file reads as Chinese, and its long first cue is still there after
  /// seeking into its middle: an external file is loaded whole, so nothing
  /// depends on where reading restarted.
  func testGBKFileLoadsAndSurvivesSeeking() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }

    let track = try await session.addExternalSubtitle(
      try fixture("external_gbk.srt"), language: "chi", title: "外挂")
    XCTAssertEqual(track.kind, .subtitle)
    XCTAssertTrue(track.isExternal)
    XCTAssertEqual(track.language, "chi")
    XCTAssertEqual(track.title, "外挂")
    let tracks = await session.tracks
    XCTAssertEqual(tracks.last, track, "external tracks follow the container's")

    try await session.selectSubtitleTrack(track.id)
    try await session.seek(to: CMTime(seconds: 3, preferredTimescale: 600))
    let shown = await session.currentSubtitleCues.map(\.plainText)
    XCTAssertEqual(shown, ["外挂字幕的第一条，持续四秒钟，用来检验定位之后长条目仍然显示。"])

    try await session.seek(to: CMTime(seconds: 5.5, preferredTimescale: 600))
    let second = await session.currentSubtitleCues.map(\.plainText)
    XCTAssertEqual(second, ["第二条字幕：简体中文，国标扩展编码。"])
  }

  /// An ASS file keeps its styles; the byte order mark does not leak into
  /// the header and break the first section.
  func testASSWithByteOrderMarkKeepsItsStyle() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }

    let track = try await session.addExternalSubtitle(try fixture("external_bom.ass"))
    XCTAssertEqual(track.codecName, "ass")
    try await session.selectSubtitleTrack(track.id)
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    let cues = await session.currentSubtitleCues
    XCTAssertEqual(cues.map(\.plainText), ["外挂 ASS"])
    XCTAssertEqual(cues.first?.alignment, .topCenter)
  }

  func testTwoFilesGetDistinctIDs() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }
    let first = try await session.addExternalSubtitle(try fixture("external_gbk.srt"))
    let second = try await session.addExternalSubtitle(try fixture("external_bom.ass"))
    XCTAssertNotEqual(first.id, second.id)
    let containerIDs = await session.tracks.filter { !$0.isExternal }.map(\.id)
    XCTAssertFalse(containerIDs.contains(first.id))
  }

  func testNonSubtitleFileIsRejected() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }
    do {
      _ = try await session.addExternalSubtitle(try fixture("audio_only.m4a"))
      XCTFail("an audio file is not a subtitle file")
    } catch let error as UmbelError {
      guard case .unsupportedContainer = error else { return XCTFail("\(error)") }
    }
    let tracks = await session.tracks
    XCTAssertFalse(tracks.contains { $0.isExternal })
  }

  /// A cap on reading: someone passing a film by mistake should get an error,
  /// not a player that swallows it into memory.
  func testOversizedSourceIsRejected() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }
    do {
      _ = try await session.addExternalSubtitle(EndlessSource())
      XCTFail("an endless source must hit the cap")
    } catch let error as UmbelError {
      guard case .unsupportedContainer = error else { return XCTFail("\(error)") }
    }
  }
}
