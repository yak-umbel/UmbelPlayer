import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

final class DecoderBackpressureSessionTests: XCTestCase {
  func testVideoDoesNotSilentlyDiscardPacketsWhenBackpressureCannotClear() async throws {
    let demux = try await opened("moov_at_end.mp4")
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoder = try await demux.makeVideoDecoder(for: track.id, preferHardware: false)
    var sends = 0
    decoder.operations.send = { _, _ in sends += 1; return -EAGAIN }
    decoder.operations.receive = { _, _ in -EAGAIN }
    let session = VideoDecodeSession(decoder: decoder)
    addTeardownBlock { await session.close() }
    let packet = try await firstPacket(on: track.id, from: demux)

    do {
      _ = try await session.decode(packet)
      XCTFail("unresolved backpressure must not silently drop a valid packet")
    } catch UmbelError.decoderFailure(let codec, let code) {
      XCTAssertEqual(codec, "video")
      XCTAssertEqual(code, -EAGAIN)
    }
    let rejected = await session.rejectedPacketCount
    XCTAssertEqual(rejected, 0, "backpressure is not a corrupt packet")
    XCTAssertGreaterThan(sends, 1, "receive, then retry before reporting failure")
    XCTAssertLessThan(sends, 100, "retries must be bounded")
  }

  func testAudioDoesNotSilentlyDiscardPacketsWhenBackpressureCannotClear() async throws {
    let demux = try await opened("audio_only.m4a")
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await demux.makeAudioDecoder(for: track.id)
    var sends = 0
    decoder.operations.send = { _, _ in sends += 1; return -EAGAIN }
    decoder.operations.receive = { _, _ in -EAGAIN }
    let session = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await session.close() }
    let packet = try await firstPacket(on: track.id, from: demux)

    do {
      _ = try await session.decode(packet)
      XCTFail("unresolved backpressure must not silently drop a valid packet")
    } catch UmbelError.decoderFailure(let codec, let code) {
      XCTAssertEqual(codec, "audio")
      XCTAssertEqual(code, -EAGAIN)
    }
    let rejected = await session.rejectedPacketCount
    XCTAssertEqual(rejected, 0)
    XCTAssertGreaterThan(sends, 1)
    XCTAssertLessThan(sends, 100)
  }

  private func opened(_ name: String) async throws -> DemuxSession {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  private func firstPacket(on track: UmbelTrack.ID, from demux: DemuxSession) async throws -> DemuxPacket {
    while let packet = try await demux.nextPacket() {
      if packet.trackID == track { return packet }
    }
    XCTFail("fixture has no packet on selected track")
    throw UmbelError.decoderFailure(codec: "fixture", code: 0)
  }
}
