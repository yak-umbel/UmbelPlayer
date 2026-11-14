import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

/// Which segment sources are open, across every source one ledger hands out.
private final class SourceLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var open: [UUID: String] = [:]

  func opened(_ id: UUID, _ name: String) { lock.withLock { open[id] = name } }
  func closed(_ id: UUID) { lock.withLock { _ = open.removeValue(forKey: id) } }
  var stillOpen: [String] { lock.withLock { open.values.sorted() } }
}

/// A segment served as a slow server would: reads of `slow` take `delay`,
/// unless the source is invalidated meanwhile, which ends them at once.
private actor GatedSource: UmbelRandomAccessSource {
  private let inner: any UmbelRandomAccessSource
  private let delay: Double
  private let ledger: SourceLedger
  private let id = UUID()
  private var isInvalidated = false

  init(url: URL, server: FixtureServer, slow: Set<String>, delay: Double, ledger: SourceLedger) {
    inner = server.source(url)
    self.delay = slow.contains(url.lastPathComponent) ? delay : 0
    self.ledger = ledger
    ledger.opened(id, url.lastPathComponent)
  }

  var contentLength: Int64? { get async { await inner.contentLength } }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    let deadline = Date().addingTimeInterval(delay)
    while !isInvalidated, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    guard !isInvalidated else { throw UmbelError.interrupted }
    return try await inner.read(offset: offset, maxLength: maxLength)
  }

  func invalidate() async {
    isInvalidated = true
    ledger.closed(id)
  }
}

/// hls/ad.m3u8 seeked twice, the second time while the first still opens
/// its segment: a host's buttons pressed again on a slow network.
final class OverlappingSeekTests: XCTestCase {
  private static let slowDelay = 5.0

  private func demuxer(slow: Set<String>, ledger: SourceLedger) async throws -> PlaylistDemuxer {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls/ad.m3u8")
    let playlist = try HLSMediaPlaylist.parse(String(contentsOf: url, encoding: .utf8), base: url)
    let server = FixtureServer()
    let demuxer = PlaylistDemuxer(
      playlist: playlist,
      open: { GatedSource(url: $0, server: server, slow: slow, delay: Self.slowDelay, ledger: ledger) },
      configuration: FFmpegDemuxerConfiguration(
        analyzeDurationMicroseconds: 1_000_000, formatName: "mpegts"))
    try await demuxer.open()
    return demuxer
  }

  private func videoTimes(_ demuxer: PlaylistDemuxer, count: Int) async throws -> [Double] {
    let tracks = await demuxer.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video }?.id)
    var times: [Double] = []
    while times.count < count, let packet = try await demuxer.nextPacket() {
      if packet.trackID == video { times.append(packet.presentationTime.seconds) }
    }
    return times
  }

  /// The second seek is the one read from — not its first keyframe and
  /// then the first seek's segment.
  func testTheLaterSeekIsTheOneReadFrom() async throws {
    let ledger = SourceLedger()
    let demuxer = try await demuxer(slow: ["main4"], ledger: ledger)
    let first = Task { try await demuxer.seek(to: CMTime(seconds: 12.5, preferredTimescale: 600)) }
    try await Task.sleep(nanoseconds: 100_000_000)
    try await demuxer.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600))
    try await first.value

    let times = try await videoTimes(demuxer, count: 25)
    XCTAssertEqual(times.first ?? -1, 2, accuracy: 0.05)
    XCTAssertEqual(times.count, 25)
    XCTAssertLessThan(times.max() ?? 99, 3.5, "everything read follows on from the second target")
    await demuxer.close()
  }

  /// The first seek's slow read is cut short rather than waited out, and
  /// what it opened is closed.
  func testASupersededSeekStopsReadingAndLeavesNothingOpen() async throws {
    let ledger = SourceLedger()
    let demuxer = try await demuxer(slow: ["main4"], ledger: ledger)
    let started = Date()
    let first = Task { try await demuxer.seek(to: CMTime(seconds: 12.5, preferredTimescale: 600)) }
    try await Task.sleep(nanoseconds: 100_000_000)
    try await demuxer.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600))
    try await first.value
    XCTAssertLessThan(Date().timeIntervalSince(started), Self.slowDelay / 2)
    XCTAssertFalse(ledger.stillOpen.contains("main4"), "the superseded segment is closed")

    await demuxer.close()
    XCTAssertEqual(ledger.stillOpen, [], "closing leaves no segment open")
  }

  /// Three in a row: only the last lands, and none of them throws.
  func testOnlyTheLastOfThreeLands() async throws {
    let ledger = SourceLedger()
    let demuxer = try await demuxer(slow: ["main4", "main5"], ledger: ledger)
    let first = Task { try await demuxer.seek(to: CMTime(seconds: 12.5, preferredTimescale: 600)) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let second = Task { try await demuxer.seek(to: CMTime(seconds: 14.5, preferredTimescale: 600)) }
    try await Task.sleep(nanoseconds: 50_000_000)
    try await demuxer.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
    try await first.value
    try await second.value

    let times = try await videoTimes(demuxer, count: 10)
    XCTAssertEqual(times.first ?? -1, 0, accuracy: 0.05)
    XCTAssertLessThan(times.max() ?? 99, 2)
    await demuxer.close()
  }
}
