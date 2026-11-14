import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// The timeline starts at zero, whatever the file's timestamps start at.
///
/// Broadcast recordings and VOBs cut from a disc carry timestamps from
/// wherever the clock stood — tens or thousands of seconds in. The duration
/// is a length, seeks and the clock count from zero; the timestamps have to
/// as well, or a seek lands before the file and the picture never catches
/// up.
///
/// dvb_subs_offset.ts starts at about 101.39 s and lasts 4 s.
final class TimelineStartTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func opened() async throws -> DemuxSession {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("dvb_subs_offset.ts")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  /// The first timestamp of each kind of track, read from here on.
  private func firstTimes(_ demux: DemuxSession) async throws -> [UmbelTrack.Kind: Double] {
    let tracks = await demux.tracks
    var first: [UmbelTrack.Kind: Double] = [:]
    var read = 0
    while first.count < 2, read < 500, let packet = try await demux.nextPacket() {
      read += 1
      guard packet.presentationTime.isValid,
            let kind = tracks.first(where: { $0.id == packet.trackID })?.kind,
            kind == .audio || kind == .video, first[kind] == nil else { continue }
      first[kind] = packet.presentationTime.seconds
    }
    return first
  }

  func testPacketsStartAtZero() async throws {
    let demux = try await opened()
    let duration = await demux.duration
    XCTAssertEqual(duration.seconds, 4, accuracy: 0.1)
    let first = try await firstTimes(demux)
    XCTAssertEqual(try XCTUnwrap(first[.audio]), 0, accuracy: 0.05, "audio starts the file")
    XCTAssertEqual(try XCTUnwrap(first[.video]), 0.01, accuracy: 0.05)
  }

  /// A seek to 2 s lands 2 s into the file, not before its start.
  func testSeekCountsFromTheStartToo() async throws {
    let demux = try await opened()
    try await demux.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
    let first = try await firstTimes(demux)
    let video = try XCTUnwrap(first[.video])
    XCTAssertGreaterThan(video, 1.4, "within a group of pictures of the target")
    XCTAssertLessThanOrEqual(video, 2.05)
  }

  /// Subtitle preroll asks the index where a line started. The question and
  /// the answer are both on the timeline: the line runs 0.5–3.5 s in a file
  /// whose timestamps start at 50 s.
  func testIndexLookupsAreOnTheTimelineToo() async throws {
    let demux = DemuxSession(
      source: try UmbelFileSource(url: fixture("clustered_subs_offset.mkv")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let target = CMTime(seconds: 2, preferredTimescale: 600)
    // Matroska reads its index on the first seek.
    try await demux.seek(to: target)
    let start = await demux.indexedTime(of: UmbelTrack.ID(rawValue: 2), atOrBefore: target)
    XCTAssertEqual(try XCTUnwrap(start).seconds, 0.5, accuracy: 0.001)
  }

  /// Through a whole session: the picture after a seek is on the same
  /// timeline as the seek. A transport stream has no index of key frames,
  /// so it lands within a group of pictures of the target rather than on it.
  func testSessionShowsThePictureAtTheTarget() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("dvb_subs_offset.ts")),
      audioOutput: VirtualAudioOutput(hostTime: HeldHost()), videoRenderer: renderer,
      hostTime: HeldHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 2, preferredTimescale: 600))

    var shown: PresentedFrame?
    for _ in 0..<200 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    let frame = try XCTUnwrap(shown, "a picture after the seek")
    XCTAssertGreaterThan(frame.presentationTime.seconds, 1.4)
    XCTAssertLessThan(frame.presentationTime.seconds, 2.5)
  }
}
