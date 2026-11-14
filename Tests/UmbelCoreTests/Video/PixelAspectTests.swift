import CoreGraphics
import CoreMedia
import Metal
import QuartzCore
import XCTest
@testable import UmbelCore

/// Pixels that are not square: DVDs and standard-definition broadcasts store
/// 352×288 or 720×576 and show them 16:9 or 4:3. Placed by pixel count, the
/// picture comes out squeezed.
///
/// anamorphic.ts declares 16:9 in its bitstream — pixels 16:11 wide.
/// anamorphic_container.mkv is the same bitstream in a container that
/// declares 4:3 — pixels 12:11 — and the container wins, as FFmpeg's own
/// guess has it.
final class PixelAspectTests: XCTestCase {
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func opened(_ name: String) async throws -> DemuxSession {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  func testTrackDeclaresItsPixelShape() async throws {
    for (name, ratio, width) in [
      ("anamorphic.ts", 16.0 / 11, 512), ("anamorphic_container.mkv", 12.0 / 11, 384),
    ] {
      let tracks = try await opened(name).tracks
      let video = try XCTUnwrap(tracks.first { $0.kind == .video }?.video)
      XCTAssertEqual(video.width, 352)
      XCTAssertEqual(video.pixelAspectRatio, ratio, accuracy: 1e-9, name)
      XCTAssertEqual(video.displayWidth, width, name)
    }
  }

  func testFramesCarryThePixelShape() async throws {
    for (name, ratio) in [("anamorphic.ts", 16.0 / 11), ("anamorphic_container.mkv", 12.0 / 11)] {
      let demux = try await opened(name)
      let tracks = await demux.tracks
      let video = try XCTUnwrap(tracks.first { $0.kind == .video })
      let session = VideoDecodeSession(
        decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
      addTeardownBlock { await session.close() }
      var first: VideoFrame?
      while first == nil, let packet = try await demux.nextPacket() {
        guard packet.trackID == video.id else { continue }
        first = try await session.decode(packet).first
      }
      if first == nil { first = try await session.drain().first }
      let frame = try XCTUnwrap(first, name)
      XCTAssertEqual(frame.pixelAspectRatio, ratio, accuracy: 1e-9, name)
    }
  }

  private func pipeline() throws -> MetalPipeline {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return try MetalPipeline(device: device)
  }

  /// 352×288 grey, pixels 16:11 wide: 512×288 on screen.
  private func wideFrame() -> VideoFrame {
    let buffer = VideoFrame.makeTestPixelBuffer(width: 352, height: 288, luma: 126, cb: 128, cr: 128)!
    return VideoFrame(
      presentationTime: .zero, pixelBuffer: buffer, width: 352, height: 288,
      color: VideoColorDescription(matrix: .bt709, range: .limited), pixelAspectRatio: 16.0 / 11)
  }

  /// In a 512×288 output the picture fills it; placed by pixel count it
  /// would be 352 wide with bars either side.
  func testRendererShowsThePictureAtItsDisplayShape() async throws {
    let renderer = OffscreenVideoRenderer(
      pipeline: try pipeline(), outputSize: CGSize(width: 512, height: 288), tolerance: tolerance)
    try await renderer.prepare(
      width: 352, height: 288, color: VideoColorDescription(matrix: .bt709, range: .limited))
    try await renderer.enqueue(wideFrame())
    _ = try await renderer.presentFrame(at: .zero)

    let nearEdge = try await renderer.readPixel(x: 500, y: 144)
    XCTAssertEqual(Int(nearEdge.g), 128, accuracy: 3, "picture, not a bar")
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 512, height: 288), "subtitles are laid out for the picture as shown")
  }

  /// The track's shape is known before any frame: subtitles laid out for
  /// the first frame already fit it.
  func testPreparingForATrackUsesItsShape() async throws {
    let renderer = OffscreenVideoRenderer(
      pipeline: try pipeline(), outputSize: CGSize(width: 512, height: 288), tolerance: tolerance)
    let track = UmbelTrack(
      id: .init(rawValue: 0), kind: .video, codecName: "mpeg2video", language: nil, title: nil,
      isDefault: true, isForced: false,
      video: .init(width: 352, height: 288, nominalFrameRate: 25, pixelAspectRatio: 16.0 / 11),
      audio: nil)
    try await renderer.prepare(for: track)
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 512, height: 288))
  }

  func testOnScreenCanvasFollowsThePixelShape() async throws {
    let layer = CAMetalLayer()
    layer.drawableSize = CGSize(width: 512, height: 288)
    let renderer = MetalVideoRenderer(pipeline: try pipeline(), layer: layer, tolerance: tolerance)
    try await renderer.prepare(
      width: 352, height: 288, color: VideoColorDescription(matrix: .bt709, range: .limited))
    try await renderer.enqueue(wideFrame())
    _ = try await renderer.presentFrame(at: .zero)
    let canvas = await renderer.subtitleCanvasSize
    XCTAssertEqual(canvas, CGSize(width: 512, height: 288))
  }
}
