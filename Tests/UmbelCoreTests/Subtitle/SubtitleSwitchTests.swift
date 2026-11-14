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
    defer { lock.unlock() }
    seconds += delta
  }
}

/// Switching to another subtitle track mid-play shows the line on screen
/// on it now, not only the next one.
///
/// styled_subs.mkv: track 4 is SRT with "second tagged" from 2.0 to 4.0 s,
/// track 3 ASS with "sign on top" over the same span.
final class SubtitleSwitchTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// Played to 2.5 s with no subtitles — by then everything is read and
  /// every subtitle packet behind the playhead has left the cache.
  private func playing(to seconds: Double) async throws -> PlaybackSession {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("styled_subs.mkv")), audioOutput: output,
      hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.selectSubtitleTrack(nil)
    try await session.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    for _ in 0..<Int(seconds / 0.1) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
    let now = await session.currentTime
    XCTAssertEqual(now.seconds, seconds, accuracy: 0.05)
    return session
  }

  private func showing(_ session: PlaybackSession) async throws -> [String] {
    for _ in 0..<100 {
      let texts = await session.currentSubtitleCues.map(\.plainText)
      if !texts.isEmpty { return texts }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return []
  }

  func testTheLineOnScreenShowsAtOnce() async throws {
    let session = try await playing(to: 2.5)
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 4))
    let texts = try await showing(session)
    XCTAssertEqual(texts, ["second tagged"])
  }

  /// Back to a track shown before: its packets went to a decoder since
  /// closed, and the line still has to come back.
  func testSwitchingBackShowsTheLineAgain() async throws {
    let session = try await playing(to: 2.5)
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 4))
    _ = try await showing(session)
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 3))
    let ass = try await showing(session)
    XCTAssertEqual(ass, ["sign on top"])
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 4))
    let again = try await showing(session)
    XCTAssertEqual(again, ["second tagged"])
  }
}
