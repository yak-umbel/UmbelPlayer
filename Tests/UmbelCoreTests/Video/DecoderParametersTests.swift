import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

/// A playlist can move on to content encoded otherwise: its packets carry
/// the parameters they decode with, and a decode session given packets
/// with other ones makes a decoder for them.
final class DecoderParametersTests: XCTestCase {
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

  private func track(_ kind: UmbelTrack.Kind, in demux: DemuxSession, codec: String? = nil) async throws -> UmbelTrack {
    let tracks = await demux.tracks
    return try XCTUnwrap(tracks.first { $0.kind == kind && (codec == nil || $0.codecName == codec) })
  }

  /// Packets of one kind, each carrying that file's parameters.
  private func packets(
    of kind: UmbelTrack.Kind, in demux: DemuxSession, limit: Int
  ) async throws -> [DemuxPacket] {
    let chosen = try await track(kind, in: demux)
    let found = await demux.codecParameters(for: chosen.id)
    let parameters = try XCTUnwrap(found)
    var result: [DemuxPacket] = []
    while result.count < limit, var packet = try await demux.nextPacket() {
      guard packet.trackID == chosen.id else { continue }
      packet.decoderParameters = parameters
      result.append(packet)
    }
    return result
  }

  func testVideoOfAnotherCodecGetsADecoderOfItsOwn() async throws {
    let first = try await opened("multi_track.mkv")  // MPEG-4 Part 2
    let video = try await track(.video, in: first)
    let session = VideoDecodeSession(decoder: try await first.makeVideoDecoder(for: video.id))
    let other = try await opened("sync_check.mp4")  // H.264
    var frames: [VideoFrame] = []
    for packet in try await packets(of: .video, in: other, limit: 30) {
      frames += try await session.decode(packet)
    }
    XCTAssertFalse(frames.isEmpty, "an MPEG-4 decoder makes nothing of H.264")
    let rebuilt = await session.rebuildCount
    XCTAssertEqual(rebuilt, 1, "once, not per packet")
  }

  func testSoundOfAnotherCodecStillComesOutInTheSameFormat() async throws {
    let first = try await opened("multi_track.mkv")
    let aac = try await track(.audio, in: first, codec: "aac")  // 44.1 kHz mono
    let session = AudioDecodeSession(decoder: try await first.makeAudioDecoder(for: aac.id))
    let other = try await opened("sync_check.mp4")  // AAC too, but 48 kHz
    var frames: [AudioFrame] = []
    for packet in try await packets(of: .audio, in: other, limit: 40) {
      frames += try await session.decode(packet)
    }
    XCTAssertFalse(frames.isEmpty)
    XCTAssertTrue(frames.allSatisfy { $0.sampleRate == 44_100 && $0.channelCount == 1 },
                  "the first track's format, which the output was prepared in")
    let rebuilt = await session.rebuildCount
    XCTAssertEqual(rebuilt, 1)
  }

  func testTheSameParametersKeepTheDecoder() async throws {
    let demux = try await opened("sync_check.mp4")
    let video = try await track(.video, in: demux)
    let decoder = try await demux.makeVideoDecoder(for: video.id)
    let session = VideoDecodeSession(decoder: decoder)
    let parameters = try XCTUnwrap(decoder.parameters)
    while var packet = try await demux.nextPacket() {
      guard packet.trackID == video.id else { continue }
      packet.decoderParameters = parameters
      _ = try await session.decode(packet)
    }
    let rebuilt = await session.rebuildCount
    XCTAssertEqual(rebuilt, 0)
  }
}
