import CoreMedia
import XCTest
@testable import UmbelCore

/// Decoded through the engine, frames say whether they are interlaced, which
/// field is first and how long they last.
final class InterlacedFrameTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func frames(of name: String) async throws -> [VideoFrame] {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video }, name)
    let session = VideoDecodeSession(decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    addTeardownBlock { await session.close() }
    var frames: [VideoFrame] = []
    while let packet = try await demux.nextPacket() {
      guard packet.trackID == video.id else { continue }
      frames += try await session.decode(packet)
    }
    frames += try await session.drain()
    XCTAssertFalse(frames.isEmpty, name)
    return frames
  }

  func testTheFieldOrderComesThrough() async throws {
    for frame in try await frames(of: "interlaced_tff.ts") { XCTAssertEqual(frame.fieldOrder, .topFirst) }
    for frame in try await frames(of: "interlaced_bff.ts") { XCTAssertEqual(frame.fieldOrder, .bottomFirst) }
    for frame in try await frames(of: "short.mp4") { XCTAssertNil(frame.fieldOrder) }
  }

  /// The engine hands the packet's duration to the decoder, so the frame has
  /// one: without it the second field's time could only be guessed.
  func testTheDurationComesThrough() async throws {
    for frame in try await frames(of: "interlaced_tff.ts") {
      XCTAssertEqual(frame.duration.seconds, 0.04, accuracy: 1e-6)
    }
  }
}
