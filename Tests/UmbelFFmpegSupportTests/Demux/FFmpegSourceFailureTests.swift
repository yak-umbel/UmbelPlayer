import XCTest
@testable import UmbelFFmpegSupport

/// A file served from memory whose source goes bad at an offset and stays so —
/// a network that is gone — counting how often it is asked after that.
private actor GoneSource {
  struct Gone: Error, Equatable {}

  private let data: Data
  private var position = 0
  private var failAt: Int?
  private(set) var failedReads = 0

  init(_ data: Data) { self.data = data }

  func failFrom(_ offset: Int?) { failAt = offset }

  func read(maxLength: Int) throws -> Data {
    if let failAt, position >= failAt {
      failedReads += 1
      throw Gone()
    }
    guard position < data.count else { return Data() }
    // A read that starts before the offset stops short of it.
    let stop = min(failAt ?? data.count, data.count)
    let end = min(position + maxLength, stop)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }

  var length: Int64 { Int64(data.count) }
}

private func demuxer(over source: GoneSource) -> FFmpegDemuxer {
  FFmpegDemuxer(
    callbacks: FFmpegIOCallbacks(
      read: { maxLength in try await source.read(maxLength: maxLength) },
      seek: { offset in await source.seek(to: offset) },
      totalLength: { await source.length },
      canSeek: true),
    configuration: FFmpegDemuxerConfiguration(
      ioBufferSize: 4096, probeSize: 8192, analyzeDurationMicroseconds: 100_000))
}

/// A source that has failed is not asked again until the failure is told, and
/// reading goes on as before once it has been: the I/O callback holds off a
/// source that failed (see `FFmpegIOFailureTests`), which the demuxer must
/// not leave holding off for good.
final class FFmpegSourceFailureTests: XCTestCase {
  /// seek_grid.mp4 keeps its pictures from about 20 KB on and its index at the
  /// end, which `open` has read by then. Cut at 15 KB, a seek to eight
  /// seconds lands on bytes past it.
  private let cut = 15_000

  private func openedAndCut() async throws -> (FFmpegDemuxer, GoneSource) {
    let data = try Data(contentsOf: FixtureLocator.url(for: "seek_grid.mp4"))
    let source = GoneSource(data)
    let demuxer = demuxer(over: source)
    try await demuxer.open()
    await source.failFrom(cut)
    return (demuxer, source)
  }

  /// A failure is over once it is told: a seek is a fresh attempt, and what
  /// the source has by then is read.
  func testReadingGoesOnAfterAFailureAndASeek() async throws {
    let (demuxer, source) = try await openedAndCut()
    try await demuxer.seek(toSeconds: 8)
    do {
      _ = try await demuxer.readPacket()
      XCTFail("a source that is gone is no end of file")
    } catch is GoneSource.Gone {}

    await source.failFrom(nil)
    try await demuxer.seek(toSeconds: 1)
    let packet = try await demuxer.readPacket()
    XCTAssertNotNil(packet)
    await demuxer.close()
  }

  /// Telling a failure ends it too, with no seek: the read after it is asked
  /// of the source as any other.
  func testAFailureToldIsOverForTheNextRead() async throws {
    let (demuxer, source) = try await openedAndCut()
    try await demuxer.seek(toSeconds: 8)
    do {
      _ = try await demuxer.readPacket()
      XCTFail("a source that is gone is no end of file")
    } catch is GoneSource.Gone {}
    let before = await source.failedReads

    do {
      _ = try await demuxer.readPacket()
    } catch {}
    let after = await source.failedReads
    XCTAssertEqual(before, 1)
    XCTAssertLessThanOrEqual(after - before, 1, "a read asks the source at most once")
    await demuxer.close()
  }
}
