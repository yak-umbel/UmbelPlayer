import CoreMedia
import CoreVideo
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

final class VideoPresentationStatusTests: XCTestCase {
  private final class Sink: SampleBufferSink, @unchecked Sendable {
    func enqueue(_ buffer: CMSampleBuffer) {}
    func flush() {}
    var hasFailed: Bool { false }
    var isReadyForMoreMediaData: Bool { true }
  }

  func testQualityStatusNamesTheActivePictureInPictureOutput() async throws {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let main = try OffscreenVideoRenderer(device: gpu, tolerance: .zero)
    let pip = try SampleBufferVideoRenderer(sink: Sink(), device: gpu, tolerance: .zero)
    let renderer = SwitchingVideoRenderer(main: main, pictureInPicture: pip)
    let observation = VideoPresentationObservation(diagnostics: nil)
    await renderer.setVideoPresentationObservation(observation, output: "video")
    let pixel = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(width: 4, height: 4, luma: 100, cb: 128, cr: 128))
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: pixel, width: 4, height: 4,
      color: .init(matrix: .bt709, range: .limited))
    try await renderer.prepare(width: 4, height: 4, color: frame.color)
    try await renderer.enqueue(frame)
    _ = try await renderer.presentFrame(at: .zero)
    await renderer.show(.pictureInPicture)
    _ = try await renderer.presentFrame(at: .zero)
    XCTAssertEqual(observation.snapshot.output, "video.pictureInPicture")
  }
  func testLossesAreSeparateAndRepeatedFramesDoNotRepeatEvents() throws {
    let diagnostics = UmbelPlaybackDiagnostics()
    let observation = VideoPresentationObservation(diagnostics: diagnostics)
    let pixel = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(width: 4, height: 4, luma: 500, cb: 512, cr: 512))
    var frame = VideoFrame(presentationTime: .zero, pixelBuffer: pixel, width: 4, height: 4,
                          color: .init(matrix: .bt709, range: .limited))
    frame.sourcePixelDescription = .init(cvFormat: kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange)
    observation.observe(frame, output: "video", target: .standard)
    observation.observe(frame, output: "video", target: .standard)
    XCTAssertEqual(observation.snapshot.qualityChanges, ["bitDepthReduction", "chromaSubsampling"])
    let events = diagnostics.snapshot().events.filter { $0.name == "video_quality_changed" }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.labels["sourceBits"], "16")
    XCTAssertEqual(events.first?.labels["outputBits"], "8")
  }

  func testSessionStateExistsWithoutDiagnostics() async throws {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: gpu, tolerance: .zero)
    let source = try UmbelFileSource(url: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hevc10_white.mp4"))
    let session = PlaybackSession(source: source, videoRenderer: renderer,
      videoPolicy: .init(dynamicMetadata: .compatibleBaseLayer))
    try await session.load()
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let status = await session.videoPresentationStatus
    XCTAssertEqual(status.route, .metalPixels)
    XCTAssertEqual(status.decoded?.effectiveBits, 10)
    XCTAssertFalse(status.qualityChanges.contains("bitDepthReduction"))
    XCTAssertFalse(status.effectValidated)
    await session.stop()
    let stopped = await session.videoPresentationStatus
    XCTAssertNil(stopped.route)
  }
}
