import CoreMedia
import XCTest
@testable import UmbelCore

final class SubtitleDecodeSessionTests: XCTestCase {
  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1000)
  }

  private func packet(_ text: Data, at seconds: Double, lasting duration: Double) -> DemuxPacket {
    DemuxPacket(
      trackID: UmbelTrack.ID(rawValue: 3), data: text,
      presentationTime: time(seconds), decodeTime: time(seconds),
      duration: time(duration), isKeyframe: true)
  }

  private func englishSession() async throws -> (SubtitleDecodeSession, DemuxSession) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL("multi_track.mkv")))
    try await demux.open()
    let decoder = try await demux.makeSubtitleDecoder(for: UmbelTrack.ID(rawValue: 3))
    return (SubtitleDecodeSession(decoder: decoder), demux)
  }

  func testDecodedPacketBecomesACue() async throws {
    let (session, demux) = try await englishSession()
    addTeardownBlock { await session.close(); await demux.close() }

    await session.receive(packet(Data("hello there".utf8), at: 4, lasting: 1))
    let showing = await session.cues(at: time(4.5)).map(\.plainText)
    XCTAssertEqual(showing, ["hello there"])
    let after = await session.cues(at: time(5)).map(\.plainText)
    XCTAssertEqual(after, [], "the packet duration is the end")
  }

  /// A packet the decoder rejects is counted and skipped, and the next one
  /// still decodes. Invalid UTF-8 is what FFmpeg refuses for text subtitles.
  func testBadPacketIsCountedAndSkipped() async throws {
    let (session, demux) = try await englishSession()
    addTeardownBlock { await session.close(); await demux.close() }

    await session.receive(packet(Data([0xFF, 0xFE, 0xC3, 0x28]), at: 1, lasting: 1))
    let failures = await session.failedPacketCount
    XCTAssertEqual(failures, 1)
    let nothing = await session.cues(at: time(1.5))
    XCTAssertTrue(nothing.isEmpty)

    await session.receive(packet(Data("after".utf8), at: 2, lasting: 1))
    let showing = await session.cues(at: time(2.5)).map(\.plainText)
    XCTAssertEqual(showing, ["after"])
  }

  func testFlushEmptiesTheTimeline() async throws {
    let (session, demux) = try await englishSession()
    addTeardownBlock { await session.close(); await demux.close() }

    await session.receive(packet(Data("before seek".utf8), at: 1, lasting: 10))
    await session.flush()
    let showing = await session.cues(at: time(5))
    XCTAssertTrue(showing.isEmpty)
  }

  // ── Bitmap subtitles ─────────────────────────────────

  /// Every subtitle packet of a fixture's first subtitle track, through a
  /// decode session.
  private func bitmapSession(
    _ fixture: String, fallbackCanvas: CGSize? = nil
  ) async throws -> SubtitleDecodeSession {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixtureURL(fixture)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .subtitle })
    let session = SubtitleDecodeSession(
      decoder: try await demux.makeSubtitleDecoder(for: track.id), fallbackCanvas: fallbackCanvas)
    addTeardownBlock { await session.close() }
    while let packet = try await demux.nextPacket() {
      if packet.trackID == track.id { await session.receive(packet) }
    }
    return session
  }

  /// Placed as fractions of the canvas, so any picture size can use them.
  /// The fixture: white at (110, 200) 100×20 from 0.5 s, cleared at 2.0 s;
  /// red at (40, 20) 60×30 from 2.5 s — on a 320×240 canvas.
  func testPGSBecomesPlacedImagesAndClears() async throws {
    let session = try await bitmapSession("pgs_subs.mkv")

    let atOne = await session.cues(at: time(1))
    let white = try XCTUnwrap(atOne.first?.image)
    XCTAssertEqual(white.relativeFrame.minX, 110.0 / 320, accuracy: 1e-9)
    XCTAssertEqual(white.relativeFrame.minY, 200.0 / 240, accuracy: 1e-9)
    XCTAssertEqual(white.relativeFrame.width, 100.0 / 320, accuracy: 1e-9)
    XCTAssertEqual(white.relativeFrame.height, 20.0 / 240, accuracy: 1e-9)
    XCTAssertEqual(white.image.width, 100)
    XCTAssertEqual(white.image.height, 20)

    let cleared = await session.cues(at: time(2.2))
    XCTAssertTrue(cleared.isEmpty, "the empty event at 2.0 s cleared the screen")

    let atThree = await session.cues(at: time(3))
    let red = try XCTUnwrap(atThree.first?.image)
    XCTAssertEqual(red.relativeFrame.minX, 40.0 / 320, accuracy: 1e-9)
  }

  func testDVDSubtitlesBecomePlacedImages() async throws {
    let session = try await bitmapSession("dvd_subs.mkv")
    let atOne = await session.cues(at: time(1))
    let white = try XCTUnwrap(atOne.first?.image)
    XCTAssertEqual(white.relativeFrame.minY, 200.0 / 240, accuracy: 1e-9)
    let gap = await session.cues(at: time(2.2))
    XCTAssertTrue(gap.isEmpty)
  }

  /// DVB, in a transport stream whose timestamps start near 101.39 s: the
  /// events land on the timeline counted from zero — white 0.51–2.01 s,
  /// red from 2.51 s.
  func testDVBSubtitlesBecomePlacedImagesOnTheTimeline() async throws {
    let session = try await bitmapSession("dvb_subs_offset.ts")
    let atOne = await session.cues(at: time(1))
    let white = try XCTUnwrap(atOne.first?.image)
    XCTAssertEqual(white.relativeFrame.minX, 110.0 / 320, accuracy: 1e-9)
    XCTAssertEqual(white.relativeFrame.minY, 200.0 / 240, accuracy: 1e-9)
    let gap = await session.cues(at: time(2.2))
    XCTAssertTrue(gap.isEmpty, "cleared at 2.01 s")
    let atThree = await session.cues(at: time(3))
    XCTAssertNotNil(atThree.first?.image)
  }
}
