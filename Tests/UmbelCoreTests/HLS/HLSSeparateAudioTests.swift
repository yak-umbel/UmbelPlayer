import CoreMedia
import XCTest
@testable import UmbelCore

final class HLSSeparateAudioTests: XCTestCase {
  private func opened() async throws -> DemuxSession {
    let source = UmbelHTTPSource(
      url: URL(string: "https://origin.invalid/hls/alt_fmp4/master.m3u8")!,
      headers: HeaderStubProtocol.headers, session: HeaderStubProtocol.session())
    let demux = DemuxSession(source: source)
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  /// Both playlists describe ranges of one fragmented file. Reading the
  /// first range alone would end the six-second film at two seconds.
  func testSeparateFragmentedTracksPlayEveryByteRange() async throws {
    let demux = try await opened()
    let tracks = await demux.tracks
    XCTAssertEqual(tracks.map(\.kind.rawValue).sorted(), ["audio", "video"])
    var times: [UmbelTrack.ID: [Double]] = [:]
    while let packet = try await demux.nextPacket() {
      times[packet.trackID, default: []].append(packet.presentationTime.seconds)
    }
    for track in tracks {
      let values = times[track.id, default: []].sorted()
      XCTAssertEqual(values.first ?? -1, 0, accuracy: 0.05)
      XCTAssertEqual(values.last ?? -1, 6, accuracy: 0.05, "\(track.kind) reaches the last segment")
      XCTAssertLessThan(zip(values, values.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.05)
    }
  }

  /// A response window cannot seek through the whole file, but seeking
  /// the presentation must still open the right ranges, even after EOF.
  func testRangeWindowsRemainSeekableAsAPlaylist() async throws {
    let demux = try await opened()
    let seekable = await demux.isSeekable
    XCTAssertTrue(seekable)
    let tracks = await demux.tracks
    for target in [4.5, 1.0] {
      try await demux.seek(to: CMTime(seconds: target, preferredTimescale: 600))
      var times: [UmbelTrack.ID: [Double]] = [:]
      while let packet = try await demux.nextPacket() {
        times[packet.trackID, default: []].append(packet.presentationTime.seconds)
      }
      for track in tracks {
        let values = times[track.id, default: []]
        XCTAssertLessThanOrEqual(values.min() ?? 99, target + 0.05)
        XCTAssertGreaterThanOrEqual(values.min() ?? -1, max(0, target - 2.1))
        XCTAssertEqual(values.max() ?? -1, 6, accuracy: 0.05, "\(track.kind) plays on after seeking")
      }
    }
  }
}
