import CoreMedia
import XCTest
@testable import UmbelCore
import UmbelFFmpegSupport

/// A packet the decoder refuses is skipped and counted, not fatal.
///
/// Files cut at an arbitrary byte — a VOB sliced out of a disc, a broadcast
/// recording started mid-stream — begin with a partial packet, and damaged
/// streams carry them anywhere. FFmpeg's own tools log such a packet and
/// carry on; failing the whole film over one would be the odd one out.
final class CorruptPacketTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func opened(_ name: String) async throws -> DemuxSession {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  /// Three bytes of noise where a packet should be: what a cut leaves.
  private func garbage(on track: UmbelTrack.ID) -> DemuxPacket {
    let zero = CMTime(value: 0, timescale: 1000)
    return DemuxPacket(
      trackID: track, data: Data([0xFF, 0xFF, 0xFF]), presentationTime: zero,
      decodeTime: zero, duration: .invalid, isKeyframe: true)
  }

  func testAudioSkipsAPacketItCannotDecodeAndCarriesOn() async throws {
    let demux = try await opened("audio_only.m4a")
    let tracks = await demux.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let session = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: audio.id))
    addTeardownBlock { await session.close() }

    let fromGarbage = try await session.decode(garbage(on: audio.id))
    XCTAssertTrue(fromGarbage.isEmpty)
    let rejected = await session.rejectedPacketCount
    XCTAssertEqual(rejected, 1, "counted, so a stream that is all damage can still be told apart")

    var decoded = 0
    while decoded == 0, let packet = try await demux.nextPacket() {
      guard packet.trackID == audio.id else { continue }
      decoded += try await session.decode(packet).count
    }
    XCTAssertGreaterThan(decoded, 0, "the packets after it still decode")
  }

  func testVideoSkipsAPacketItCannotDecodeAndCarriesOn() async throws {
    let demux = try await opened("multi_track.mkv")
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    addTeardownBlock { await session.close() }

    let fromGarbage = try await session.decode(garbage(on: video.id))
    XCTAssertTrue(fromGarbage.isEmpty)

    var decoded = 0
    while decoded == 0, let packet = try await demux.nextPacket() {
      guard packet.trackID == video.id else { continue }
      decoded += try await session.decode(packet).count
    }
    XCTAssertGreaterThan(decoded, 0)
    // Decoding on several threads, the damage is reported later: when a
    // later packet is sent, or when its frame would have been due — which
    // one depends on when the thread finishes. Either way, by the time
    // frames come out after it.
    let rejected = await session.rejectedPacketCount
    XCTAssertEqual(rejected, 1)
  }

  /// A packet after the decoder was drained is our mistake, not damage in
  /// the file: it must still fail rather than vanish into the count.
  func testAPacketAfterDrainingStillFails() async throws {
    let demux = try await opened("audio_only.m4a")
    let tracks = await demux.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await demux.makeAudioDecoder(for: audio.id)
    var packet: DemuxPacket?
    while packet == nil, let next = try await demux.nextPacket() {
      if next.trackID == audio.id { packet = next }
    }
    let first = try XCTUnwrap(packet)
    // Drained straight on the decoder, past the session's own guard.
    _ = try decoder.decode(
      FFmpegPacket(
        streamIndex: 0, data: Data(), pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
        duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false))
    let session = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await session.close() }
    do {
      _ = try await session.decode(first)
      XCTFail("a drained decoder takes no more packets")
    } catch UmbelError.decoderFailure {
    }
  }
}
