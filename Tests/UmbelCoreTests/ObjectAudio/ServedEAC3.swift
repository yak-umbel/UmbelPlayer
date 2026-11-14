import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// eac3_movie.mkv's sound made into a playlist, initialization segment and
/// fragments, served on loopback: what the system player is given.
enum ServedEAC3 {
  static func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// The playlist's address, the track's shift, and the server to unregister from.
  static func serve() async throws -> (server: LoopbackServer, playlist: URL, shift: CMTime) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("eac3_movie.mkv")))
    try await demux.open()
    let tracks = await demux.tracks
    let sound = try XCTUnwrap(tracks.first { $0.kind == .audio })
    var packets: [DemuxPacket] = []
    while let packet = try await demux.nextPacket() {
      if packet.trackID == sound.id { packets.append(packet) }
    }
    let found = await demux.codecParameters(for: sound.id)
    let parameters = try XCTUnwrap(found)
    let duration = await demux.duration
    await demux.close()

    let shift = CMTime(seconds: max(0, -packets[0].presentationTime.seconds), preferredTimescale: 1_000)
    let track = try FragmentedAudioTrack.make(parameters: parameters, leading: Array(packets.prefix(4)), shift: shift)
    let plan = SegmentPlan(
      frameDuration: CMTime(value: 1536, timescale: 48_000), framesPerSegment: 63, duration: duration, shift: shift)
    let groups = Dictionary(grouping: packets) { plan.index(of: $0.presentationTime) }
    let playlist = Data(plan.playlist(initName: "init.mp4", segmentName: { "seg\($0).m4s" }).utf8)
    let initSegment = track.initSegment
    let fragments = groups.mapValues { track.fragment(sequence: 1, packets: $0) }
    let server = LoopbackServer()
    let base = try await server.register { name in
      switch name {
      case "index.m3u8": return .init(data: playlist, contentType: "application/vnd.apple.mpegurl")
      case "init.mp4": return .init(data: initSegment, contentType: "video/mp4")
      default:
        guard name.hasPrefix("seg"), let index = Int(name.dropFirst(3).dropLast(4)), let fragment = fragments[index]
        else { return nil }
        return .init(data: fragment, contentType: "video/mp4")
      }
    }
    return (server, base.appendingPathComponent("index.m3u8"), shift)
  }

  /// Waits for actual playback; failure to start must fail the integration test.
  static func waitUntilPlaying(_ player: AVPlayer) async throws {
    for _ in 0..<100 {
      if player.timeControlStatus == .playing { return }
      if let error = player.currentItem?.error { throw error }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw NSError(domain: "UmbelPlaybackTest", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "playback did not start: \(String(describing: player.reasonForWaitingToPlay))",
    ])
  }
}
