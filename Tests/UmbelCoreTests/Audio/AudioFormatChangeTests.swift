import XCTest
@testable import UmbelCore

/// Sound comes out in one format — the track's — even when the content's
/// changes midway. Played in the output's format, a part at another rate
/// would play fast and high.
final class AudioFormatChangeTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// rate_change.ts: two seconds at 48 kHz stereo, then two at 44.1 kHz mono.
  func testSoundComesOutInTheTracksFormatThroughout() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("rate_change.ts")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let session = AudioDecodeSession(decoder: try await demux.makeAudioDecoder(for: track.id))

    var frames: [AudioFrame] = []
    while let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      frames += try await session.decode(packet)
    }
    frames += try await session.drain()

    XCTAssertFalse(frames.isEmpty)
    XCTAssertTrue(frames.allSatisfy { $0.sampleRate == 48_000 && $0.channelCount == 2 })
    let seconds = frames.reduce(0.0) { $0 + Double($1.frameCount) / $1.sampleRate }
    XCTAssertEqual(seconds, 4.0, accuracy: 0.1, "two seconds of each part, not faster")
  }

  func testTheOutputIsPreparedInTheTracksFormat() {
    let track = UmbelTrack(
      id: UmbelTrack.ID(rawValue: 1), kind: .audio, codecName: "aac", language: nil,
      title: nil, isDefault: true, isForced: false, video: nil,
      audio: UmbelTrack.AudioDescription(channelCount: 6, sampleRate: 44_100))
    XCTAssertEqual(AudioOutputFormat.for(track), AudioOutputFormat(sampleRate: 44_100, channelCount: 6))
  }
}
