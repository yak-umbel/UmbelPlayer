import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

/// A renderer with no display layer behind it: pictures it draws itself only.
private actor DrawingOnlyRenderer: VideoRenderer {
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { get async { .zero } }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// One with a display layer behind it, where the system can or cannot show DV.
private actor LayerBackedRenderer: SystemDecodedVideoShowing, SystemPixelVideoShowing {
  let showsSystemDecodedDV: Bool
  let showsP84SystemPixels = false
  let showsP81SystemPixels: Bool
  init(showsDV: Bool, showsP81: Bool = false) {
    showsSystemDecodedDV = showsDV
    showsP81SystemPixels = showsP81
  }
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { get async { 0 } }
  var totalDroppedFrames: Int { get async { 0 } }
  var subtitleCanvasSize: CGSize { get async { .zero } }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// Which session a video track's packets go to.
final class VideoRouteTests: XCTestCase {
  func testIndependentP81PixelCandidateUsesTheBoundedFallbackPath() async throws {
    let (demux, track) = try await opened("dv_p81.mp4")
    let observation = VideoPresentationObservation(diagnostics: nil)
    let source = try await VideoRoute.session(for: track, demux: demux,
      renderer: LayerBackedRenderer(showsDV: false, showsP81: true), observation: observation)
    addTeardownBlock { await source.close() }
    XCTAssertTrue(source is VideoPath)
    XCTAssertEqual(observation.snapshot.route, .systemPixels)
    XCTAssertEqual(observation.snapshot.metadata, .declared)
    XCTAssertFalse(observation.snapshot.effectValidated)
  }

  func testP81PixelCapabilitySurvivesTheSwitchingRenderer() async throws {
    let (demux, track) = try await opened("dv_p81.mp4")
    let renderer = SwitchingVideoRenderer(main: DrawingOnlyRenderer(),
      pictureInPicture: LayerBackedRenderer(showsDV: false, showsP81: true))
    let observation = VideoPresentationObservation(diagnostics: nil)
    let source = try await VideoRoute.session(for: track, demux: demux,
      renderer: renderer, observation: observation)
    await source.close()
    XCTAssertTrue(source is VideoPath)
    XCTAssertEqual(observation.snapshot.route, .systemPixels)
  }

  func testUnsupportedP81MetadataVersionFallsBackAtCreation() async throws {
    var data = try Data(contentsOf: fixture("dv_p81.mp4"))
    let box = try XCTUnwrap(data.range(of: Data("dvvC".utf8)))
    data[box.upperBound] = 2
    let demux = DemuxSession(source: MemorySource(data: data))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let parameters = await demux.codecParameters(for: track.id)
    XCTAssertEqual(parameters?.dovi?.versionMajor, 2)
    let observation = VideoPresentationObservation(diagnostics: nil)
    let source = try await VideoRoute.session(for: track, demux: demux,
      renderer: LayerBackedRenderer(showsDV: false, showsP81: true), observation: observation)
    addTeardownBlock { await source.close() }
    XCTAssertTrue(source is VideoDecodeSession)
    XCTAssertEqual(observation.snapshot.route, .metalPixels)
    XCTAssertEqual(observation.snapshot.metadata, .baseLayerFallback)
    XCTAssertNotNil(observation.snapshot.reason)
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func opened(_ name: String) async throws -> (DemuxSession, UmbelTrack) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    return (demux, try XCTUnwrap(tracks.first { $0.kind == .video }))
  }

  func testP5WithoutADisplayLayerAsksForOne() async throws {
    let (demux, track) = try await opened("dv_p5.mp4")
    do {
      _ = try await VideoRoute.session(for: track, demux: demux, renderer: DrawingOnlyRenderer())
      XCTFail("a renderer without a display layer was accepted for DV P5")
    } catch UmbelError.displayLayerRequired {
    }
  }

  func testP5WhereTheSystemCannotShowItIsRefused() async throws {
    let (demux, track) = try await opened("dv_p5.mp4")
    do {
      _ = try await VideoRoute.session(for: track, demux: demux, renderer: LayerBackedRenderer(showsDV: false))
      XCTFail("DV P5 was accepted where the system cannot show it")
    } catch UmbelError.unsupportedDynamicHDR(let what) {
      XCTAssertEqual(what, "DV P5")
    }
  }

  func testP5GoesToTheSystem() async throws {
    let (demux, track) = try await opened("dv_p5.mp4")
    let session = try await VideoRoute.session(
      for: track, demux: demux, renderer: LayerBackedRenderer(showsDV: true))
    XCTAssertTrue(session is SystemDecodeSession)
  }

  func testExplicitAsyncRouteUsesAsyncDecoder() async throws {
    let (demux, track) = try await opened("hdr10_pq.mp4")
    let session = try await VideoRoute.session(
      for: track, demux: demux, renderer: DrawingOnlyRenderer(), mode: .asynchronous)
    addTeardownBlock { await session.close() }
    XCTAssertTrue(session is AsyncVideoDecodeSession)
  }

  func testP5RemainsSystemManagedForBothRequestedModes() async throws {
    for mode in [UmbelVideoDecodingMode.synchronous, .asynchronous] {
      let (demux, track) = try await opened("dv_p5.mp4")
      let decoder = try await VideoRoute.session(
        for: track, demux: demux, renderer: LayerBackedRenderer(showsDV: true), mode: mode)
      XCTAssertTrue(decoder is SystemDecodeSession)
      await decoder.close()
      let session = PlaybackSession(
        source: try UmbelFileSource(url: fixture("dv_p5.mp4")),
        videoRenderer: LayerBackedRenderer(showsDV: true), videoDecodingMode: mode)
      addTeardownBlock { await session.stop() }
      let before = await session.videoDecodingStatus
      XCTAssertEqual(before, .inactive)
      try await session.load()
      let status = await session.videoDecodingStatus
      XCTAssertEqual(status, .systemManaged)
      let requested = await session.videoDecodingMode
      XCTAssertEqual(requested, mode)
    }
  }

  /// Decoded here, its base layer's colour where the frames declare none.
  func testP81IsDecodedWithItsBaseLayer() async throws {
    let (demux, track) = try await opened("dv_p81_untagged.mp4")
    let session = try await VideoRoute.session(for: track, demux: demux, renderer: DrawingOnlyRenderer())
    XCTAssertTrue(session is VideoDecodeSession)
    addTeardownBlock { await session.close() }
    var frame: VideoFrame?
    var read = 0
    while frame == nil, read < 100, let packet = try await demux.nextPacket() {
      read += 1
      if packet.trackID == track.id { frame = try await session.decode(packet, hidden: false).first }
    }
    if frame == nil { frame = try await session.drain().first }
    XCTAssertEqual(try XCTUnwrap(frame).color.transfer, .pq)
  }

  func testPlainHEVCIsDecodedAsBefore() async throws {
    let (demux, track) = try await opened("hdr10_pq.mp4")
    let session = try await VideoRoute.session(for: track, demux: demux, renderer: DrawingOnlyRenderer())
    XCTAssertTrue(session is VideoDecodeSession)
    await session.close()
  }

  func testTheNewErrorsAreNotRetryable() {
    XCTAssertFalse(UmbelError.unsupportedDynamicHDR("DV P5").isRetryable)
    XCTAssertFalse(UmbelError.displayLayerRequired.isRetryable)
    XCTAssertEqual(
      UmbelError.unsupportedDynamicHDR("DV P5").errorDescription,
      "dynamic HDR not supported here: DV P5")
  }
}
