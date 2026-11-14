import XCTest
@testable import UmbelFFmpegSupport

private struct ConnectionCut: Error, Equatable {}

/// The first bytes of something, then a failure: a connection that was cut.
private actor CutAfterBytes {
  private let data: Data
  private let limit: Int
  private var position = 0

  init(_ data: Data, limit: Int) {
    self.data = data
    self.limit = limit
  }

  func read(maxLength: Int) throws -> Data {
    guard position < limit else { throw ConnectionCut() }
    let end = min(position + maxLength, limit)
    defer { position = end }
    return data.subdata(in: position..<end)
  }
}

final class FFmpegReadFailureTests: XCTestCase {
  private func cutDemuxer() throws -> FFmpegDemuxer {
    let payload = try Data(contentsOf: FixtureLocator.url(for: "live_like.ts"))
    let source = CutAfterBytes(payload, limit: payload.count / 2)
    return FFmpegDemuxer(
      callbacks: FFmpegIOCallbacks(
        read: { try await source.read(maxLength: $0) }, seek: { _ in throw ConnectionCut() },
        totalLength: { nil }, canSeek: false),
      configuration: .init())
  }

  /// FFmpeg reads ahead of the packet it returns, so a source's failure is
  /// often hit during a call that still hands back a packet from what was
  /// buffered. It has to be told by the call that cannot be served, as it
  /// was: FFmpeg's own error for it is the bare code of an interruption, and
  /// reported as that a cut connection reads as the host's own stop.
  func testAFailureHitWhileReadingAheadIsToldWhenThePacketsRunOut() async throws {
    let demuxer = try cutDemuxer()
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    var packets = 0
    do {
      while try await demuxer.readPacket() != nil { packets += 1 }
      XCTFail("a cut stream ended as if it were complete")
    } catch is ConnectionCut {
      // Told as it was.
    } catch {
      XCTFail("a cut connection was reported as \(error)")
    }
    XCTAssertGreaterThan(packets, 0, "what was buffered before the cut is still read")
  }

  /// The other way round: once the host has asked to stop, what comes next is
  /// the stop, not a failure that was waiting to be told.
  func testAStopAfterAFailureWasHitIsAStopNotThatFailure() async throws {
    let counting = try cutDemuxer()
    try await counting.open()
    var before = 0
    do {
      while try await counting.readPacket() != nil { before += 1 }
    } catch {}
    await counting.close()
    XCTAssertGreaterThan(before, 0)

    let demuxer = try cutDemuxer()
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    for _ in 0..<before { _ = try await demuxer.readPacket() }
    demuxer.requestInterrupt()
    do {
      _ = try await demuxer.readPacket()
      XCTFail("a stopped demuxer gave a packet")
    } catch FFmpegDemuxerError.interrupted {
      // The stop.
    } catch {
      XCTFail("a stop was reported as \(error)")
    }
  }
}
