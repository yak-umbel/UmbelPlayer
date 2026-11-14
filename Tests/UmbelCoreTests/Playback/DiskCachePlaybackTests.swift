import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// A source that is never there: the network is down.
private struct Unreachable: UmbelRandomAccessSource {
  var contentLength: Int64? { get async { nil } }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    throw UmbelError.sourceUnavailable(detail: "offline")
  }
  func invalidate() async {}
}

/// Played once through the disk cache, a film plays again with the source
/// gone: loaded, seeked and shown from disk alone.
final class DiskCachePlaybackTests: XCTestCase {
  private var directory: URL!
  private var cache: UmbelDiskCache!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DiskCachePlaybackTests-\(UUID().uuidString)")
    // Small blocks, so the fixture spans many of them.
    cache = try UmbelDiskCache(directory: directory, capacity: 100_000_000, blockSize: 4096)
  }

  override func tearDown() async throws {
    await cache.close()
    try? FileManager.default.removeItem(at: directory)
  }

  private func fixture() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("seek_grid.mp4")
  }

  /// Reads the whole file through the cache, as a play to the end would.
  private func readThrough(key: String) async throws {
    let demux = DemuxSession(
      source: UmbelDiskCacheSource(
        wrapping: try UmbelFileSource(url: fixture()), key: key, cache: cache))
    try await demux.open()
    while try await demux.nextPacket() != nil {}
    await demux.close()
  }

  private func offlineSession(key: String) throws -> (PlaybackSession, OffscreenVideoRenderer) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let source = UmbelBufferedSource(
      wrapping: UmbelDiskCacheSource(wrapping: Unreachable(), key: key, cache: cache),
      chunkSize: 4096)
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: HeldHost()),
      videoRenderer: renderer, hostTime: HeldHost())
    return (session, renderer)
  }

  func testAFilmPlayedOncePlaysAgainOffline() async throws {
    try await readThrough(key: "seek_grid")
    let held = await cache.cachedBytes(forKey: "seek_grid")
    let size = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: fixture().path)[.size] as? NSNumber)
    XCTAssertEqual(held, size.int64Value, "every byte read once is on disk")

    let (session, _) = try offlineSession(key: "seek_grid")
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    var shown: PresentedFrame?
    for _ in 0..<200 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    let frame = try XCTUnwrap(shown, "a picture, from disk alone")
    XCTAssertEqual(frame.presentationTime.seconds, 1, accuracy: 0.05)
  }

  /// The control: under a key nothing was cached for, the same offline
  /// session cannot even open the film.
  func testWithoutTheCacheTheSameSessionCannotOpen() async throws {
    try await readThrough(key: "seek_grid")
    let (session, _) = try offlineSession(key: "another film")
    do {
      try await session.load()
      XCTFail("nothing cached under this key")
    } catch {
    }
    await session.stop()
  }
}
