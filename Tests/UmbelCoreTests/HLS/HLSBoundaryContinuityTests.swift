import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

final class HLSBoundaryContinuityTests: XCTestCase {
  private func bytes(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls")
    return try Data(contentsOf: root.appendingPathComponent(name))
  }

  private func packets(first: Data, second: Data) async throws -> [DemuxPacket] {
    let contents = ["first": first, "second": second]
    let playlist = try HLSMediaPlaylist.parse("""
      #EXTM3U
      #EXT-X-TARGETDURATION:4
      #EXTINF:4,
      first
      #EXTINF:2,
      second
      #EXT-X-ENDLIST
      """, base: URL(string: "https://media.invalid/index.m3u8")!)
    let demuxer = PlaylistDemuxer(playlist: playlist,
      open: { MemorySource(data: contents[$0.lastPathComponent]!) },
      configuration: .init(analyzeDurationMicroseconds: 100_000, formatName: "mpegts"))
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    var packets: [DemuxPacket] = []
    while let packet = try await demuxer.nextPacket() { packets.append(packet) }
    return packets
  }

  func testContinuousBoundaryAfterAnInternalGapDoesNotRewind() async throws {
    let read = try await packets(first: bytes("main0") + bytes("main2"), second: bytes("main3"))
    for track in Set(read.map(\.trackID)) {
      let times = read.filter { $0.trackID == track }.map(\.presentationTime.seconds)
      XCTAssertTrue(zip(times, times.dropFirst()).allSatisfy { $1 >= $0 })
      XCTAssertEqual(times.last ?? -1, 7.96, accuracy: 0.1)
    }
  }

  func testMissingPrefixDoesNotAddAGapAtAContinuousBoundary() async throws {
    let read = try await packets(first: bytes("main1"), second: bytes("main2"))
    for track in Set(read.map(\.trackID)) {
      let times = read.filter { $0.trackID == track }.map(\.presentationTime.seconds)
      XCTAssertLessThan(zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.1)
      XCTAssertEqual(times.last ?? -1, 3.96, accuracy: 0.1)
    }
  }
}
