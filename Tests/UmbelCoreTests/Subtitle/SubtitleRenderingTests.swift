import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// `renderSubtitles(in:)`: libass for ASS tracks, CoreText for the rest.
///
/// styled_subs.mkv's ASS track is written for 640 × 360, the size rendered
/// here, so its coordinates are output pixels.
final class SubtitleRenderingTests: XCTestCase {
  private let size = CGSize(width: 640, height: 360)

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func session() async throws -> PlaybackSession {
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("styled_subs.mkv")),
      audioOutput: VirtualAudioOutput(hostTime: HeldHost()), hostTime: HeldHost())
    try await session.load()
    return session
  }

  /// Renders until something shows: packets reach the decoders a moment
  /// after the seek returns.
  private func firstPicture(_ session: PlaybackSession) async throws -> UmbelSubtitleFrame {
    for _ in 0..<100 {
      let frame = await session.renderSubtitles(in: size)
      if !frame.bitmaps.isEmpty { return frame }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("nothing rendered")
    return UmbelSubtitleFrame(bitmaps: [], isChanged: false)
  }

  private func bounds(_ frame: UmbelSubtitleFrame) -> CGRect {
    frame.bitmaps.map(\.frame).reduce(CGRect.null) { $0.union($1) }
  }

  /// The line is `{\pos(160,90)}placed`. CoreText ignores `\pos` and would
  /// put it at the bottom centre; near (160, 90) means libass drew it.
  func testASSTrackIsDrawnByLibass() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 3))
    try await session.seek(to: CMTime(seconds: 4.5, preferredTimescale: 600))

    let drawn = bounds(try await firstPicture(session))
    XCTAssertEqual(drawn.midX, 160, accuracy: 10)
    XCTAssertEqual(drawn.midY, 90, accuracy: 15)
  }

  func testOtherTextTracksAreDrawnByCoreText() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 4))   // SRT
    try await session.seek(to: CMTime(seconds: 0.6, preferredTimescale: 600))

    let drawn = bounds(try await firstPicture(session))
    XCTAssertGreaterThan(drawn.midY, size.height / 2, "bottom, where SRT goes")
    XCTAssertEqual(drawn.midX, size.width / 2, accuracy: 3)
  }

  /// Asked every frame, the picture is composited again only when it
  /// changes; a different track always counts as a change.
  func testChangesAreReportedOnlyWhenThePictureChanges() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 3))
    try await session.seek(to: CMTime(seconds: 4.5, preferredTimescale: 600))
    _ = try await firstPicture(session)

    let again = await session.renderSubtitles(in: size)
    XCTAssertFalse(again.isChanged)
    XCTAssertFalse(again.bitmaps.isEmpty, "unchanged still hands back the picture")

    try await session.selectSubtitleTrack(nil)
    let off = await session.renderSubtitles(in: size)
    XCTAssertTrue(off.isChanged)
    XCTAssertTrue(off.bitmaps.isEmpty)
    let stillOff = await session.renderSubtitles(in: size)
    XCTAssertFalse(stillOff.isChanged)
  }

  /// Back to a track whose last picture the CoreText renderer still holds:
  /// that renderer sees the same input as before and would say nothing
  /// changed, while the screen still shows the other track's picture.
  ///
  /// External tracks, because their cues are there the moment they are
  /// chosen. With embedded ones the first render after a switch comes up
  /// empty while packets are decoded, and that empty frame already counts as
  /// a change — hiding the case this test is about.
  func testSwitchingBackToATrackStillCountsAsAChange() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    let text = try await session.addExternalSubtitle(
      try UmbelFileSource(url: fixture("external_gbk.srt")))
    let styled = try await session.addExternalSubtitle(
      try UmbelFileSource(url: fixture("external_bom.ass")))
    // Both files have a line showing at 1.2 s.
    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))

    try await session.selectSubtitleTrack(text.id)      // CoreText
    let first = await session.renderSubtitles(in: size)
    XCTAssertFalse(first.bitmaps.isEmpty)
    try await session.selectSubtitleTrack(styled.id)    // libass
    let other = await session.renderSubtitles(in: size)
    XCTAssertFalse(other.bitmaps.isEmpty)

    try await session.selectSubtitleTrack(text.id)
    let back = await session.renderSubtitles(in: size)
    XCTAssertTrue(back.isChanged)
  }

  /// An external ASS file goes to libass whole; its style aligns it to the top.
  func testExternalASSFileIsDrawnByLibass() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    let track = try await session.addExternalSubtitle(
      try UmbelFileSource(url: fixture("external_bom.ass")))
    try await session.selectSubtitleTrack(track.id)
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))

    let drawn = bounds(try await firstPicture(session))
    XCTAssertLessThan(drawn.midY, size.height / 2)
  }

  func testPlacementMovesCachedASSFrameAndReportsChange() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    let track = try await session.addExternalSubtitle(
      try UmbelFileSource(url: fixture("external_bom.ass")))
    try await session.selectSubtitleTrack(track.id)
    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    let original = await session.renderSubtitles(in: size)
    XCTAssertFalse(original.bitmaps.isEmpty)
    let again = await session.renderSubtitles(in: size)
    XCTAssertFalse(again.isChanged)

    await session.setSubtitlePlacement(.init(verticalOffset: -0.1))
    let moved = await session.renderSubtitles(in: size)
    XCTAssertTrue(moved.isChanged)
    XCTAssertEqual(bounds(moved).midY, bounds(original).midY + 36, accuracy: 1)
    let unchanged = await session.renderSubtitles(in: size)
    XCTAssertFalse(unchanged.isChanged)

    await session.setSubtitlePlacement(.init())
    let restored = await session.renderSubtitles(in: size)
    XCTAssertTrue(restored.isChanged)
    XCTAssertEqual(bounds(restored), bounds(original))
  }

  func testSnapshotUsesPlacementAtItsOwnResolution() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    let track = try await session.addExternalSubtitle(
      try UmbelFileSource(url: fixture("external_gbk.srt")))
    try await session.selectSubtitleTrack(track.id)
    try await session.seek(to: CMTime(seconds: 1.2, preferredTimescale: 600))
    let time = CMTime(seconds: 1.2, preferredTimescale: 600)
    let output = CGSize(width: 1280, height: 720)
    let original = await session.subtitles.snapshot(at: time, in: output, videoSize: size)
    XCTAssertFalse(original.isEmpty)

    await session.setSubtitlePlacement(.init(verticalOffset: 0.1))
    let moved = await session.subtitles.snapshot(at: time, in: output, videoSize: size)
    let originalBounds = original.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    let movedBounds = moved.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    XCTAssertEqual(movedBounds.midY, originalBounds.midY - 72, accuracy: 1)
  }

  func testPlacementRejectsNonFiniteInputsAndClampsFractions() async throws {
    let session = try await session()
    addTeardownBlock { await session.stop() }
    await session.setSubtitlePlacement(.init(verticalOffset: 2, bottomInset: -0.2))
    let clamped = await session.subtitlePlacement
    XCTAssertEqual(clamped.verticalOffset, 1)
    XCTAssertEqual(clamped.bottomInset, 0)

    await session.setSubtitlePlacement(.init(verticalOffset: .nan, bottomInset: 0.5))
    let unchanged = await session.subtitlePlacement
    XCTAssertEqual(unchanged, clamped)
  }
}
