import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import UmbelCore

private final class StillTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// 10-bit video — ordinary for HEVC, and nothing to do with HDR. Its frames
/// hold each sample in 16 bits; read as 8-bit they come out as noise. The
/// fixture is plain white, so a correct picture is simply bright.
final class TenBitVideoTests: XCTestCase {
  private func fixture() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("hevc10_white.mp4")
  }

  private func renderer() throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    return try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
  }

  /// Through a whole session, hardware decoding first.
  func testTenBitVideoRendersThroughASession() async throws {
    let renderer = try renderer()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture()), videoRenderer: renderer, hostTime: StillTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    for _ in 0..<100 {
      if await renderer.queueDepth > 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let shown = try await session.renderVideoFrame()
    XCTAssertNotNil(shown, "a frame to show")

    let pixel = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertGreaterThan(Int(pixel.r), 200, "white, not noise")
    XCTAssertGreaterThan(Int(pixel.g), 200)
    XCTAssertGreaterThan(Int(pixel.b), 200)
  }

  /// Software decoding, as on devices without a hardware HEVC decoder. The
  /// frame stays 10-bit rather than being cut down to 8.
  func testSoftwareDecodedTenBitStaysTenBitAndRenders() async throws {
    let renderer = try renderer()
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture()))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoding = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))

    var first: VideoFrame?
    while first == nil, let packet = try await demux.nextPacket() {
      guard packet.trackID == video.id else { continue }
      first = try await decoding.decode(packet).first
    }
    if first == nil { first = try await decoding.drain().first }
    let frame = try XCTUnwrap(first)
    XCTAssertEqual(
      CVPixelBufferGetPixelFormatType(try XCTUnwrap(frame.pixelBuffer)),
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)

    try await renderer.prepare(
      width: 320, height: 240, color: VideoColorDescription(matrix: .unspecified, range: .limited))
    try await renderer.enqueue(frame)
    let shown = try await renderer.presentFrame(at: frame.presentationTime)
    XCTAssertNotNil(shown)
    let pixel = try await renderer.readAveragePixel(inRegion: .whole)
    XCTAssertGreaterThan(Int(pixel.r), 200)
    XCTAssertGreaterThan(Int(pixel.g), 200)
    XCTAssertGreaterThan(Int(pixel.b), 200)
  }
}
