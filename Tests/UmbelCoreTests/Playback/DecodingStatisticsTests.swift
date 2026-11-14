import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

/// What the decoders have done, counted for a host's diagnostics: packets
/// read and eaten without a frame coming out show as such, rather than only
/// as buffering that never ends.
final class DecodingStatisticsTests: XCTestCase {
  private func opened(_ name: String) async throws -> DemuxSession {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  /// Three bytes of noise where a packet should be.
  private func garbage(on track: UmbelTrack.ID) -> DemuxPacket {
    let zero = CMTime(value: 0, timescale: 1000)
    return DemuxPacket(
      trackID: track, data: Data([0xFF, 0xFF, 0xFF]), presentationTime: zero,
      decodeTime: zero, duration: .invalid, isKeyframe: true)
  }

  /// A frame the decoder fails, as a hardware decoder does once its session
  /// is taken away, counts as damaged; made anew for the same track, the
  /// decoder's counts go on rather than start again.
  func testVideoCountsDecodedAndDamagedFramesAcrossARenewal() async throws {
    let demux = try await opened("moov_at_end.mp4")
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoder = try await demux.makeVideoDecoder(for: track.id, preferHardware: false)
    let receive = decoder.operations.receive
    var failed = false
    decoder.operations.receive = { context, frame in
      let status = receive(context, frame)
      guard status >= 0, !failed else { return status }
      failed = true
      return -EIO
    }
    let session = VideoDecodeSession(decoder: decoder)
    addTeardownBlock { await session.close() }

    var decoded = 0
    while decoded < 3, let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      decoded += try await session.decode(packet).count
    }
    let found = await session.decodingCounts
    let counts = try XCTUnwrap(found)
    XCTAssertEqual(counts.decodedFrames, decoded)
    XCTAssertEqual(counts.damagedFrames, 1)
    XCTAssertEqual(counts.rejectedPackets, 0)

    try await session.renew()
    let renewed = await session.decodingCounts
    XCTAssertEqual(renewed, counts, "the same track's counts go on")
  }

  func testAudioCountsDecodedFramesAndRefusedPackets() async throws {
    let demux = try await opened("audio_only.m4a")
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let session = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: track.id))
    addTeardownBlock { await session.close() }

    _ = try await session.decode(garbage(on: track.id))
    var decoded = 0
    while decoded < 5, let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      decoded += try await session.decode(packet).count
    }
    let counts = await session.decodingCounts
    XCTAssertEqual(counts, UmbelDecodingCounts(decodedFrames: decoded, rejectedPackets: 1, damagedFrames: 0))
  }

  /// Decoding on a queue of its own, the counts are read there too.
  func testVideoDecodedAheadCountsEveryFrameByTheEnd() async throws {
    let demux = try await opened("moov_at_end.mp4")
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let session = AsyncVideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: track.id, preferHardware: false))
    addTeardownBlock { await session.close() }

    var decoded = 0
    while let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      decoded += try await session.decode(packet).count
    }
    decoded += try await session.drain().count
    let found = await session.decodingCounts
    let counts = try XCTUnwrap(found)
    XCTAssertGreaterThan(decoded, 0)
    XCTAssertEqual(counts.decodedFrames, decoded)
  }

  /// The session answers for the decoders it has: here the sound's, and no
  /// picture.
  func testASessionReportsItsDecoders() async throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("audio_only.m4a")
    let output = VirtualAudioOutput(hostTime: SystemHostTimeSource())
    let session = PlaybackSession(source: try UmbelFileSource(url: url), audioOutput: output)
    addTeardownBlock { await session.stop() }
    let before = await session.decodingStatistics
    XCTAssertEqual(before, UmbelDecodingStatistics(), "nothing before loading")
    try await session.load()
    try await session.play()
    for _ in 0..<200 where (await session.decodingStatistics.audio?.decodedFrames ?? 0) == 0 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let statistics = await session.decodingStatistics
    XCTAssertGreaterThan(statistics.audio?.decodedFrames ?? 0, 0)
    XCTAssertEqual(statistics.audio?.rejectedPackets, 0)
    XCTAssertNil(statistics.video, "no picture decoded here")
  }
}
