import XCTest
@testable import UmbelCore

/// A DV base layer that declares no colour is decoded as what its
/// configuration names: an HDR10 base layer drawn as standard range would
/// come out grey and flat.
final class DVBaseLayerColorTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// The first decoded frame of the file's video.
  private func firstFrame(of name: String, baseLayer: UmbelDVBaseLayer?) async throws -> VideoFrame {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id), baseLayer: baseLayer)
    addTeardownBlock { await session.close() }
    var read = 0
    while read < 100, let packet = try await demux.nextPacket() {
      read += 1
      guard packet.trackID == video.id else { continue }
      if let frame = try await session.decode(packet).first { return frame }
    }
    let drained = try await session.drain()
    return try XCTUnwrap(drained.first)
  }

  func testUntaggedFramesTakeTheBaseLayersColour() async throws {
    let frame = try await firstFrame(of: "dv_p81_untagged.mp4", baseLayer: .hdr10)
    XCTAssertEqual(frame.color.transfer, .pq)
    XCTAssertEqual(frame.color.primaries, .bt2020)
    XCTAssertEqual(frame.color.matrix, .bt2020)
  }

  func testTaggedFramesAreLeftAlone() async throws {
    // Told the wrong base layer on purpose: what the frames declare wins.
    let frame = try await firstFrame(of: "dv_p84.mp4", baseLayer: .hdr10)
    XCTAssertEqual(frame.color.transfer, .hlg)
  }

  func testWithoutABaseLayerNothingChanges() async throws {
    let frame = try await firstFrame(of: "dv_p81_untagged.mp4", baseLayer: nil)
    XCTAssertEqual(frame.color.transfer, .sdr)
  }
}
