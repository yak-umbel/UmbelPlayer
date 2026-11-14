import CoreMedia
import XCTest
@testable import UmbelCore

private final class StillHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// styled_subs.mkv: English audio (default) and Japanese audio; an English ASS
/// track flagged default, an English SRT track, and a forced Japanese track.
final class ForcedSubtitleTests: XCTestCase {
  private func loadedSession() async throws -> PlaybackSession {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("styled_subs.mkv")
    let session = PlaybackSession(
      source: try UmbelFileSource(url: url),
      audioOutput: VirtualAudioOutput(hostTime: StillHost()), hostTime: StillHost())
    try await session.load()
    return session
  }

  private func track(
    _ session: PlaybackSession, _ kind: UmbelTrack.Kind, language: String
  ) async throws -> UmbelTrack {
    let tracks = await session.tracks
    return try XCTUnwrap(tracks.first { $0.kind == kind && $0.language == language })
  }

  private var forcedID: UmbelTrack.ID { UmbelTrack.ID(rawValue: 5) }

  func testNothingShowsForEnglishAudio() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }
    let selected = await session.selectedSubtitleTrack
    XCTAssertNil(selected, "the default-flagged ASS track is ordinary, not forced")
  }

  func testJapaneseAudioBringsItsForcedTrack() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }

    let japanese = try await track(session, .audio, language: "jpn")
    try await session.selectAudioTrack(japanese.id)
    let selected = await session.selectedSubtitleTrack
    XCTAssertEqual(selected, forcedID)

    // And it decodes: the forced cue runs from 1 s to 3 s.
    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    var shown: [String] = []
    for _ in 0..<100 {
      shown = await session.currentSubtitleCues.map(\.plainText)
      if !shown.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(shown, ["強制字幕"])

    let english = try await track(session, .audio, language: "eng")
    try await session.selectAudioTrack(english.id)
    let afterSwitchBack = await session.selectedSubtitleTrack
    XCTAssertNil(afterSwitchBack, "back to English: no forced track for it")
  }

  /// Choosing by hand — even choosing nothing — ends automatic selection until
  /// the host asks for it again.
  func testManualChoiceStopsAutomaticSelection() async throws {
    let session = try await loadedSession()
    addTeardownBlock { await session.stop() }
    let japanese = try await track(session, .audio, language: "jpn")
    let english = try await track(session, .audio, language: "eng")

    try await session.selectSubtitleTrack(nil)
    try await session.selectAudioTrack(japanese.id)
    let manual = await session.selectedSubtitleTrack
    XCTAssertNil(manual, "turned off by hand stays off")

    try await session.selectSubtitleTrackAutomatically()
    let automatic = await session.selectedSubtitleTrack
    XCTAssertEqual(automatic, forcedID)

    try await session.selectAudioTrack(english.id)
    try await session.selectAudioTrack(japanese.id)
    let followed = await session.selectedSubtitleTrack
    XCTAssertEqual(followed, forcedID, "automatic again: follows the audio")
  }
}
