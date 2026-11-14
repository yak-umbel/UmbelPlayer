import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

/// DV profile 5 declared turned a quarter clockwise. The system shows such a
/// picture as stored, so nothing here turns it: the track reports what the
/// stream declares, and what is drawn keeps the stored shape.
final class SystemDisplayRotationTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func opened() async throws -> (DemuxSession, UmbelTrack) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("dv_p5_rotated.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    return (demux, try XCTUnwrap(tracks.first { $0.kind == .video }))
  }

  func testTheTrackReportsTheTurnButIsDrawnAsStored() async throws {
    let (_, track) = try await opened()
    let video = try XCTUnwrap(track.video)
    XCTAssertEqual(video.dynamicHDR?.requiresSystemDisplay, true)
    XCTAssertEqual(video.rotation, .clockwise90, "the stream's declaration is reported")
    XCTAssertEqual(video.appliedRotation, UmbelVideoRotation.none)
    XCTAssertEqual(video.displayWidth, 320)
    XCTAssertEqual(video.displayHeight, 240)
  }

  func testTheFramesForTheSystemAreNotTurned() async throws {
    let (demux, track) = try await opened()
    let found = await demux.codecParameters(for: track.id)
    let parameters = try XCTUnwrap(found)
    XCTAssertEqual(parameters.rotation, 90, "the parameters do carry the turn")
    let session = try SystemDecodeSession(parameters: parameters, record: try XCTUnwrap(parameters.dovi))
    var frames: [VideoFrame] = []
    while frames.count < 3, let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      frames += try await session.decode(packet, hidden: false)
    }
    XCTAssertFalse(frames.isEmpty)
    for frame in frames {
      XCTAssertNotNil(frame.compressedSample)
      XCTAssertEqual(frame.rotation, UmbelVideoRotation.none)
      XCTAssertEqual(frame.displaySize, CGSize(width: 320, height: 240))
    }
  }
}
