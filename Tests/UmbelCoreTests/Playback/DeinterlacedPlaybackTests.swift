import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// Interlaced films through the whole engine and session: twice the pictures,
/// half a frame apart, none combed; off restores the woven frames.
final class DeinterlacedPlaybackTests: XCTestCase {
  private final class HeldTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  func testTheEngineDoublesThePicturesHalfAFrameApart() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("interlaced_tff.ts")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false),
      deinterlacer: VideoDeinterlacer(setting: DeinterlaceSwitch(), nominalFrameRate: 25))
    addTeardownBlock { await session.close() }
    var pictures: [VideoFrame] = []
    while let packet = try await demux.nextPacket() {
      guard packet.trackID == video.id else { continue }
      pictures += try await session.decode(packet)
    }
    pictures += try await session.drain()
    let decoded = await session.decodedFrameCount
    XCTAssertGreaterThan(decoded, 10)
    XCTAssertEqual(pictures.count, 2 * decoded)
    let times = pictures.map { $0.presentationTime.seconds }
    for (earlier, later) in zip(times, times.dropFirst()) { XCTAssertEqual(later - earlier, 0.02, accuracy: 1e-4) }
    for picture in pictures.dropFirst(2) {
      XCTAssertLessThan(InterlaceTestBuffers.combShare(picture.pixelBuffer!), 0.005)
    }
  }

  /// After a seek the frame before no longer comes before anything, and a
  /// decoder made again starts afresh: the engine tells its deinterlacer.
  func testASeekAndANewDecoderForgetTheFrameBefore() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("interlaced_tff.ts")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let deinterlacer = VideoDeinterlacer(setting: DeinterlaceSwitch(), nominalFrameRate: 25)
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false),
      deinterlacer: deinterlacer)
    addTeardownBlock { await session.close() }
    func decodeSome() async throws {
      var made = 0
      while made == 0, let packet = try await demux.nextPacket() {
        guard packet.trackID == video.id else { continue }
        made += try await session.decode(packet).count
      }
      XCTAssertGreaterThan(made, 0)
    }
    try await decodeSome()
    XCTAssertTrue(deinterlacer.hasPreviousFrame, "a frame was kept to judge motion by")
    await session.flush()
    XCTAssertFalse(deinterlacer.hasPreviousFrame, "forgotten by a seek")
    try await decodeSome()
    XCTAssertTrue(deinterlacer.hasPreviousFrame)
    try await session.renew()
    XCTAssertFalse(deinterlacer.hasPreviousFrame, "forgotten with the old decoder")
  }

  private func snapshot(_ name: String, mode: UmbelDeinterlacing) async throws -> CGImage {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture(name)), videoRenderer: renderer, hostTime: HeldTime())
    await session.setDeinterlacing(mode)
    let reported = await session.deinterlacing
    XCTAssertEqual(reported, mode)
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return try await session.snapshot()
  }

  func testASnapshotIsNotCombedAndOffIs() async throws {
    let on = try await snapshot("interlaced_tff.ts", mode: .automatic)
    XCTAssertLessThan(InterlaceTestBuffers.combShare(on), 0.005)
    let off = try await snapshot("interlaced_tff.ts", mode: .off)
    XCTAssertGreaterThan(InterlaceTestBuffers.combShare(off), 0.03)
  }

  func testTheSessionStartsAutomatic() async throws {
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("interlaced_tff.ts")), videoRenderer: nil, hostTime: HeldTime())
    let mode = await session.deinterlacing
    XCTAssertEqual(mode, .automatic)
  }

  func testATimelinePreviewIsNotCombed() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let url = fixture("interlaced_bff.ts")
    let preview = try await UmbelThumbnailGenerator { try UmbelFileSource(url: url) }
      .thumbnail(at: CMTime(seconds: 0.5, preferredTimescale: 600), maximumSize: CGSize(width: 320, height: 240))
    XCTAssertLessThan(InterlaceTestBuffers.combShare(preview.image), 0.005)
  }
}
