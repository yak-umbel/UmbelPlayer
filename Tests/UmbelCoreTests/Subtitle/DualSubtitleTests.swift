import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class DualStillClock: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

final class DualSubtitleTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func session() async throws -> PlaybackSession {
    let host = DualStillClock()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("styled_subs.mkv")),
      audioOutput: VirtualAudioOutput(hostTime: host), hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    return session
  }

  private func time(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
  }

  private func expect(
    _ text: [String], slot: UmbelSubtitleSlot, session: PlaybackSession,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    var seen: [String] = []
    for _ in 0..<100 {
      seen = await session.currentSubtitleCues(for: slot).map(\.plainText)
      if seen == text { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(seen, text, file: file, line: line)
  }

  func testBothEmbeddedTracksShowAcrossSeekAndDisablingPrimary() async throws {
    let session = try await session()
    try await session.selectSubtitleTrack(.init(rawValue: 3))
    try await session.selectSubtitleTrack(.init(rawValue: 4), for: .secondary)
    try await session.seek(to: time(2.5))
    try await expect(["sign on top"], slot: .primary, session: session)
    try await expect(["second tagged"], slot: .secondary, session: session)
    try await session.selectSubtitleTrack(nil)
    try await expect([], slot: .primary, session: session)
    try await expect(["second tagged"], slot: .secondary, session: session)
    try await session.seek(to: time(0.6))
    try await expect(["tagged line"], slot: .secondary, session: session)
  }

  func testSameEmbeddedTrackFeedsBothSlotsAndLateSelectionCatchesUp() async throws {
    let session = try await session()
    try await session.selectSubtitleTrack(.init(rawValue: 4))
    try await session.seek(to: time(2.5))
    try await expect(["second tagged"], slot: .primary, session: session)
    try await session.selectSubtitleTrack(.init(rawValue: 4), for: .secondary)
    try await expect(["second tagged"], slot: .secondary, session: session)
    try await session.seek(to: time(2.5))
    try await expect(["second tagged"], slot: .primary, session: session)
    try await expect(["second tagged"], slot: .secondary, session: session)
    try await session.selectSubtitleTrack(.init(rawValue: 3), for: .secondary)
    try await expect(["sign on top"], slot: .secondary, session: session)
    try await expect(["second tagged"], slot: .primary, session: session)
  }

  func testSettingsSurviveSelectionAndSeekWithoutChangingLegacyPrimary() async throws {
    let session = try await session()
    await session.setSubtitleDelay(0.25)
    await session.setSubtitleScale(1.2)
    await session.setSubtitleDelay(1, for: .secondary)
    await session.setSubtitleScale(1.6, for: .secondary)
    await session.setSubtitlePlacement(.init(verticalOffset: 0.3), for: .secondary)
    try await session.selectSubtitleTrack(.init(rawValue: 4))
    try await session.selectSubtitleTrack(.init(rawValue: 4), for: .secondary)
    try await session.seek(to: time(2.5))
    try await expect(["second tagged"], slot: .primary, session: session)
    // At 2.5 s, this layer's one-second delay shows the cue authored at
    // 0.5–2.0 s. Seek preroll must retain it for the delayed layer too.
    try await expect(["tagged line"], slot: .secondary, session: session)
    let primaryDelay = await session.subtitleDelay
    let primaryScale = await session.subtitleScale
    let secondaryDelay = await session.subtitleDelay(for: .secondary)
    let secondaryScale = await session.subtitleScale(for: .secondary)
    let secondaryPlacement = await session.subtitlePlacement(for: .secondary)
    XCTAssertEqual(primaryDelay, 0.25)
    XCTAssertEqual(primaryScale, 1.2)
    XCTAssertEqual(secondaryDelay, 1)
    XCTAssertEqual(secondaryScale, 1.6)
    XCTAssertEqual(secondaryPlacement.verticalOffset, 0.3)
    let legacy = await session.currentSubtitleCues.map(\.plainText)
    XCTAssertEqual(legacy, ["second tagged"])
  }

  func testFailedSelectionPreservesBothAndAutomaticSelectionOnlyChangesPrimary() async throws {
    let session = try await session()
    try await session.selectSubtitleTrack(.init(rawValue: 4), for: .secondary)
    do {
      try await session.selectSubtitleTrack(.init(rawValue: -99), for: .secondary)
      XCTFail("invalid track was accepted")
    } catch {}
    try await session.selectAudioTrack(.init(rawValue: 2))
    let primary = await session.selectedSubtitleTrack
    let secondary = await session.selectedSubtitleTrack(for: .secondary)
    XCTAssertEqual(primary, .init(rawValue: 5))
    XCTAssertEqual(secondary, .init(rawValue: 4))
  }

  func testFailedPrimarySelectionPreservesAutomaticForcedFollowing() async throws {
    let session = try await session()
    do {
      try await session.selectSubtitleTrack(.init(rawValue: -99))
      XCTFail("invalid track was accepted")
    } catch {}
    try await session.selectAudioTrack(.init(rawValue: 2))
    let primary = await session.selectedSubtitleTrack
    XCTAssertEqual(primary, .init(rawValue: 5), "a failed choice must not change automatic behavior")
  }

  func testIndependentExternalLayoutMatchesSnapshotAndClearsOneSlot() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("seek_grid.mp4")))
    try await demux.open()
    let controller = SubtitleController(demux: demux)
    addTeardownBlock { await controller.close(); await demux.close() }
    let track = try await controller.addExternal(
      try UmbelFileSource(url: fixture("external_gbk.srt")), language: nil, title: nil)
    try await controller.selectManually(track.id)
    try await controller.selectManually(track.id, for: .secondary)
    let canvas = CGSize(width: 640, height: 360)
    let picture = CGRect(origin: .zero, size: canvas)
    let rendered = await controller.render(at: time(2), in: canvas, picture: picture, videoSize: nil)
    XCTAssertEqual(rendered.bitmaps.count, 2)
    guard rendered.bitmaps.count == 2 else { return }
    XCTAssertEqual(rendered.bitmaps[0].frame.minY - rendered.bitmaps[1].frame.minY, 72, accuracy: 1)
    await controller.setScale(1.5, for: .secondary)
    let changed = await controller.render(at: time(2), in: canvas, picture: picture, videoSize: nil)
    let shot = await controller.snapshot(at: time(2), in: canvas, videoSize: nil)
    XCTAssertEqual(changed.bitmaps.map(\.frame), shot.map(\.frame))
    XCTAssertEqual(changed.bitmaps[0].frame, rendered.bitmaps[0].frame)
    XCTAssertGreaterThan(changed.bitmaps[1].frame.width, rendered.bitmaps[1].frame.width)
    let repeated = await controller.render(at: time(2), in: canvas, picture: picture, videoSize: nil)
    XCTAssertFalse(repeated.isChanged)
    try await controller.selectManually(nil, for: .secondary)
    let cleared = await controller.render(at: time(2), in: canvas, picture: picture, videoSize: nil)
    XCTAssertTrue(cleared.isChanged)
    XCTAssertEqual(cleared.bitmaps.count, 1)
  }
}

