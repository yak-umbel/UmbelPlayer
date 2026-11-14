import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

private final class HeldHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Each frame drawn by its own colour description, with the matrix it
/// declares. Expected values come from the matrices' definitions
/// (Kr, Kb of BT.601, BT.709, BT.2020), not from the renderer.
final class ColorRenderingTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func renderer(width: Int, height: Int) async throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    let renderer = OffscreenVideoRenderer(pipeline: try MetalPipeline(device: device), tolerance: tolerance)
    try await renderer.prepare(
      width: width, height: height, color: VideoColorDescription(matrix: .bt709, range: .limited))
    return renderer
  }

  private func centre(
    of buffer: CVPixelBuffer, width: Int, height: Int, color: VideoColorDescription
  ) async throws -> (r: Int, g: Int, b: Int) {
    let renderer = try await renderer(width: width, height: height)
    try await renderer.enqueue(
      VideoFrame(
        presentationTime: .zero, pixelBuffer: buffer, width: width, height: height, color: color))
    _ = try await renderer.presentFrame(at: .zero)
    let pixel = try await renderer.readPixel(x: width / 2, y: height / 2)
    return (Int(pixel.r), Int(pixel.g), Int(pixel.b))
  }

  /// Y 81, Cb 90, Cr 240 is pure red in BT.601. The matrices part on green:
  /// 0 under BT.601, 10 under BT.2020, 24 under BT.709. Red saturates and
  /// blue clips under all three.
  func testEachMatrixGivesItsOwnColour() async throws {
    let expected: [(UmbelColorMatrix, Int)] = [(.bt601, 0), (.bt709, 24), (.bt2020, 10)]
    for (matrix, green) in expected {
      let buffer = try XCTUnwrap(
        VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: 81, cb: 90, cr: 240))
      let pixel = try await centre(
        of: buffer, width: 64, height: 64,
        color: VideoColorDescription(matrix: matrix, range: .limited))
      XCTAssertEqual(pixel.g, green, accuracy: 3, "\(matrix)")
      XCTAssertGreaterThan(pixel.r, 250, "\(matrix)")
      XCTAssertLessThan(pixel.b, 4, "\(matrix)")
    }
  }

  /// Undeclared: standard-definition sizes get BT.601, high-definition BT.709.
  func testUndeclaredMatrixIsGuessedFromTheFrameSize() async throws {
    for (width, height, green) in [(352, 288, 0), (1280, 720, 24)] {
      let buffer = try XCTUnwrap(
        VideoFrame.makeTestPixelBuffer(width: width, height: height, luma: 81, cb: 90, cr: 240))
      let pixel = try await centre(
        of: buffer, width: width, height: height,
        color: VideoColorDescription(matrix: .unspecified, range: .limited))
      XCTAssertEqual(pixel.g, green, accuracy: 3, "\(width)×\(height)")
    }
  }

  /// The renderer was prepared for limited range; the frame says full. Full
  /// range puts 235 at 235; read as limited it would be white.
  func testTheFramesOwnRangeIsUsed() async throws {
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 64, height: 64, luma: 235, cb: 128, cr: 128))
    let pixel = try await centre(
      of: buffer, width: 64, height: 64, color: VideoColorDescription(matrix: .bt709, range: .full))
    XCTAssertEqual(pixel.g, 235, accuracy: 2)
  }

  /// Ten-bit limited range runs 64 to 940. Scaled as if it were eight-bit
  /// the ends drift by a few codes — enough to shift an HDR picture's
  /// brightness.
  func testTenBitLimitedRangeIsExact() async throws {
    // The ends must land exactly; the middle, 127.5, may round either way.
    for (code, level, slack) in [(64, 0.0, 0.5), (502, 127.5, 1), (940, 255.0, 0.5)] {
      let buffer = try XCTUnwrap(
        VideoFrame.makeTestP010PixelBuffer(width: 64, height: 64, luma: UInt16(code), cb: 512, cr: 512))
      let pixel = try await centre(
        of: buffer, width: 64, height: 64,
        color: VideoColorDescription(matrix: .bt709, range: .limited))
      XCTAssertEqual(Double(pixel.g), level, accuracy: slack, "code \(code)")
    }
  }

  // ── From real files ──────────────────────────────────

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func firstFrame(_ name: String, hardware: Bool) async throws -> VideoFrame {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let session = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: hardware))
    addTeardownBlock { await session.close() }
    var first: VideoFrame?
    while first == nil, let packet = try await demux.nextPacket() {
      if packet.trackID == video.id { first = try await session.decode(packet).first }
    }
    if first == nil { first = try await session.drain().first }
    return try XCTUnwrap(first, name)
  }

  /// HDR10 with its static metadata, however it is decoded: a P3 D65
  /// mastering display from 0.0001 to 1000 nits, content peaking at 1000
  /// with a 400-nit frame average — what Tools/make_hdr_sei.py writes.
  func testHDR10FramesCarryTheirMetadata() async throws {
    for hardware in [true, false] {
      let color = try await firstFrame("hdr10_pq.mp4", hardware: hardware).color
      XCTAssertEqual(color.matrix, .bt2020)
      XCTAssertEqual(color.transfer, .pq)
      XCTAssertEqual(color.primaries, .bt2020)
      let hdr = try XCTUnwrap(color.hdr, "hardware: \(hardware)")
      let mastering = try XCTUnwrap(hdr.masteringDisplay)
      XCTAssertEqual(mastering.maxLuminance, 1000, accuracy: 1e-6)
      XCTAssertEqual(mastering.minLuminance, 0.0001, accuracy: 1e-9)
      XCTAssertEqual(mastering.red.x, 0.68, accuracy: 1e-9)
      XCTAssertEqual(mastering.green.y, 0.69, accuracy: 1e-9)
      XCTAssertEqual(mastering.blue.x, 0.15, accuracy: 1e-9)
      XCTAssertEqual(mastering.whitePoint.x, 0.3127, accuracy: 1e-9)
      XCTAssertEqual(hdr.maxContentLightLevel, 1000)
      XCTAssertEqual(hdr.maxFrameAverageLightLevel, 400)
    }
  }

  func testHLGFramesSayHLG() async throws {
    let color = try await firstFrame("hlg.mp4", hardware: true).color
    XCTAssertEqual(color.transfer, .hlg)
    XCTAssertEqual(color.primaries, .bt2020)
    XCTAssertNil(color.hdr, "HLG carries no static metadata")
  }

  /// The track says it too, before any frame: the renderer sets the display
  /// up for HDR from it.
  func testTracksDeclareTheirTransfer() async throws {
    for (name, transfer) in [
      ("hdr10_pq.mp4", UmbelTransferFunction.pq), ("hlg.mp4", .hlg), ("bt601_sd.mp4", .sdr),
    ] {
      let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
      try await demux.open()
      let tracks = await demux.tracks
      XCTAssertEqual(tracks.first { $0.kind == .video }?.video?.transfer, transfer, name)
      await demux.close()
    }
  }

  /// A standard-definition film tagged BT.601 used to refuse to play.
  func testABT601FilmPlaysInItsColours() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here")
    }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: tolerance)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("bt601_sd.mp4")), videoRenderer: renderer,
      hostTime: HeldHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.play()
    var shown: PresentedFrame?
    for _ in 0..<200 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    XCTAssertNotNil(shown)
    let pixel = try await renderer.readPixel(x: 176, y: 144)
    // Native SMPTE 170M red, converted into BT.709 export primaries,
    // includes a small green component. Matrix and primaries are independent.
    XCTAssertEqual(Int(pixel.r), 247, accuracy: 3)
    XCTAssertEqual(Int(pixel.g), 20, accuracy: 4)
  }
}
