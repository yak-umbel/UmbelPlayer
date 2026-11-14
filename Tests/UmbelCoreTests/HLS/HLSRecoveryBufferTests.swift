import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

private actor GatedSegmentSource: UmbelRandomAccessSource {
  private let data: Data
  private let reached: XCTestExpectation
  private var paused: CheckedContinuation<Void, Never>?
  private var armed = true
  private(set) var reads = 0

  init(data: Data, reached: XCTestExpectation) {
    self.data = data
    self.reached = reached
  }

  var contentLength: Int64? { Int64(data.count) }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    reads += 1
    if armed, offset >= 65_536 {
      armed = false
      await withCheckedContinuation { continuation in
        paused = continuation
        reached.fulfill()
      }
    }
    return try await MemorySource(data: data).read(offset: offset, maxLength: maxLength)
  }

  func resume() {
    armed = false
    paused?.resume()
    paused = nil
  }

  func invalidate() { resume() }
}

final class HLSRecoveryBufferTests: XCTestCase {
  private func bytes(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls").appendingPathComponent(name)
    return try Data(contentsOf: url)
  }

  private func configuration() -> FFmpegDemuxerConfiguration {
    FFmpegDemuxerConfiguration(analyzeDurationMicroseconds: 100_000, formatName: "mpegts")
  }

  private func opened(
    names: [String], open: @escaping @Sendable (URL) async -> any UmbelRandomAccessSource,
    diagnostics: UmbelPlaybackDiagnostics
  ) async throws -> PlaylistDemuxer {
    let text = (["#EXTM3U", "#EXT-X-TARGETDURATION:2"]
      + names.flatMap { ["#EXTINF:2,", $0] } + ["#EXT-X-ENDLIST"]).joined(separator: "\n")
    let playlist = try HLSMediaPlaylist.parse(text, base: URL(string: "https://media.invalid/index.m3u8")!)
    let demuxer = PlaylistDemuxer(playlist: playlist, open: open,
      configuration: configuration(), diagnostics: diagnostics)
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    return demuxer
  }

  private func rawPackets(_ data: Data) async throws -> [FFmpegPacket] {
    let cursor = RandomAccessCursor(source: MemorySource(data: data))
    let demuxer = FFmpegDemuxer(callbacks: .init(
      read: { try await cursor.read(maxLength: $0) },
      seek: { try await cursor.seek(toOffset: $0) }, totalLength: { nil }, canSeek: false),
      configuration: configuration())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    var packets: [FFmpegPacket] = []
    while let packet = try await demuxer.readPacket() { packets.append(packet) }
    return packets
  }

  func testUnconfirmedBoundariesReleaseAllPacketsInArrivalOrder() async throws {
    let first = try bytes("main0")
    let silent = try bytes("silent0.ts")
    let tail = try bytes("main2")
    // One track disappears after a backward jump. Exercise EOF, a following
    // segment and a long segment that exceeds the corroboration packet bound.
    for (repetitions, hasTail) in [(1, false), (1, true), (12, true)] {
      let middle = (0..<repetitions).reduce(into: Data()) { data, _ in data.append(silent) }
      let contents = ["first": first, "middle": middle, "tail": tail]
      let names = hasTail ? ["first", "middle", "tail"] : ["first", "middle"]
      let diagnostics = UmbelPlaybackDiagnostics()
      let demuxer = try await opened(names: names,
        open: { MemorySource(data: contents[$0.lastPathComponent]!) }, diagnostics: diagnostics)
      var delivered: [DemuxPacket] = []
      while let packet = try await demuxer.nextPacket() { delivered.append(packet) }
      let raw = try await rawPackets(first + middle + (hasTail ? tail : Data()))
      XCTAssertEqual(delivered.map(\.data), raw.map(\.data), "every payload in original order")
      let offset = -1.4213333333333333
      for (packet, original) in zip(delivered, raw) where original.pts != FFmpegPacket.noTimestamp {
        let sourcePTS = Double(original.pts) * Double(original.timeBaseNum) / Double(original.timeBaseDen)
        XCTAssertEqual(packet.presentationTime.seconds - sourcePTS, offset, accuracy: 0.000002)
      }
      let events = diagnostics.snapshot().events
      XCTAssertFalse(events.contains { $0.name == "hls_timestamp_recovery" })
      if repetitions == 12 {
        XCTAssertTrue(events.contains { $0.name == "hls_recovery_abandoned" && $0.labels["reason"] == "limit" })
      }
    }
  }

  func testCancellingPendingCorroborationDoesNotFetchMorePackets() async throws {
    let first = try bytes("main0")
    let silent = try bytes("silent0.ts")
    let middle = (0..<12).reduce(into: Data()) { data, _ in data.append(silent) }
    let reached = expectation(description: "a read within the pending boundary")
    let gated = GatedSegmentSource(data: middle, reached: reached)
    let demuxer = try await opened(names: ["first", "middle"], open: { url in
      if url.lastPathComponent == "middle" { return gated }
      return MemorySource(data: first)
    }, diagnostics: UmbelPlaybackDiagnostics())
    let reading = Task {
      while try await demuxer.nextPacket() != nil {}
    }
    await fulfillment(of: [reached], timeout: 3)
    let readsBefore = await gated.reads
    reading.cancel()
    await gated.resume()
    do {
      try await reading.value
      XCTFail("cancelled corroboration must end with cancellation")
    } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
    let readsAfter = await gated.reads
    XCTAssertEqual(readsAfter, readsBefore, "no read beyond the one already in progress")
  }
}
