import CoreGraphics
import CoreMedia
import UmbelFFmpegSupport
import VideoToolbox
import XCTest
@testable import UmbelCore

/// A renderer with no display layer behind it: pictures it draws itself only.
private actor PlainRenderer: VideoRenderer {
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

/// One where the system shows DV itself, or shows P8.1 pictures it decoded.
private actor SystemShowingRenderer: SystemDecodedVideoShowing, SystemPixelVideoShowing {
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

/// Which decoder the picture is decoded with, and that the choice is kept.
final class VideoDecoderPreferencePlaybackTests: XCTestCase {
  private let software = UmbelVideoDecoderConfiguration(preference: .software)

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func loaded(
    _ name: String, _ configuration: UmbelVideoDecoderConfiguration? = nil,
    renderer: any VideoRenderer = PlainRenderer()
  ) async throws -> PlaybackSession {
    let source = try UmbelFileSource(url: fixture(name))
    let session = configuration.map {
      PlaybackSession(source: source, videoRenderer: renderer, videoDecoder: $0)
    } ?? PlaybackSession(source: source, videoRenderer: renderer)
    addTeardownBlock { await session.stop() }
    try await session.load()
    return session
  }

  private func opened(_ name: String) async throws -> (DemuxSession, UmbelTrack) {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    return (demux, try XCTUnwrap(tracks.first { $0.kind == .video }))
  }

  private func requireHardwareH264() throws {
    try XCTSkipUnless(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "no hardware H.264")
  }

  // ── Not asking changes nothing ──────────────────────

  func testWithoutAskingAHardwareCapableVideoIsDecodedInHardware() async throws {
    try requireHardwareH264()
    let session = try await loaded("sync_check.mp4")
    let configuration = await session.videoDecoderConfiguration
    let status = await session.videoDecoderStatus
    XCTAssertEqual(configuration, UmbelVideoDecoderConfiguration())
    XCTAssertEqual(status, .hardware)
  }

  /// MPEG-4 Part 2 has no hardware decoder to prefer: it falls back, as it
  /// did, to FFmpeg's pick of threads.
  func testWithoutAskingAVideoHardwareCannotDecodeFallsBackToSoftwareOnFFmpegsPick() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 2, "one core is one thread")
    let session = try await loaded("b_frames.mkv")
    let status = await session.videoDecoderStatus
    guard case .software(let threads) = status else { return XCTFail("\(status)") }
    XCTAssertGreaterThan(try XCTUnwrap(threads), 1)
    XCTAssertLessThanOrEqual(try XCTUnwrap(threads), 16, "FFmpeg's own pick stops at 16")
  }

  func testTheStatusIsInactiveBeforeLoadingAndAfterStopping() async throws {
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")), videoRenderer: PlainRenderer(),
      videoDecoder: software)
    let before = await session.videoDecoderStatus
    XCTAssertEqual(before, .inactive)
    try await session.load()
    let loaded = await session.videoDecoderStatus
    guard case .software = loaded else { return XCTFail("\(loaded)") }
    await session.stop()
    let stopped = await session.videoDecoderStatus
    XCTAssertEqual(stopped, .inactive)
  }

  func testWithoutAVideoOutputThereIsNoDecoder() async throws {
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("sync_check.mp4")), videoDecoder: software)
    addTeardownBlock { await session.stop() }
    try await session.load()
    let status = await session.videoDecoderStatus
    XCTAssertEqual(status, .inactive)
  }

  // ── Software ────────────────────────────────────────

  func testSoftwareIsUsedEvenWhereHardwareCouldDecode() async throws {
    try requireHardwareH264()
    let (demux, track) = try await opened("sync_check.mp4")
    let source = try await VideoRoute.session(
      for: track, demux: demux, renderer: PlainRenderer(), decoder: software)
    addTeardownBlock { await source.close() }
    let decoding = try XCTUnwrap(source as? VideoDecodeSession)
    let hardware = await decoding.isHardwareAccelerated
    XCTAssertFalse(hardware)

    var frames = 0
    while frames < 3, let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      frames += try await decoding.decode(packet).count
    }
    XCTAssertGreaterThan(frames, 0, "and decodes")
  }

  func testSoftwareIsUsedByTheAsynchronousRouteToo() async throws {
    try requireHardwareH264()
    let (demux, track) = try await opened("sync_check.mp4")
    let source = try await VideoRoute.session(
      for: track, demux: demux, renderer: PlainRenderer(), mode: .asynchronous, decoder: software)
    addTeardownBlock { await source.close() }
    XCTAssertTrue(source is AsyncVideoDecodeSession)
    let status = await source.decoderStatus
    guard case .software? = status else { return XCTFail("\(String(describing: status))") }
  }

  func testThePlaybackSessionReportsSoftware() async throws {
    try requireHardwareH264()
    let session = try await loaded("sync_check.mp4", software)
    let status = await session.videoDecoderStatus
    guard case .software = status else { return XCTFail("\(status)") }
    let configuration = await session.videoDecoderConfiguration
    XCTAssertEqual(configuration.preference, .software)
  }

  func testSoftwareDecodingPlaysTheFilm() async throws {
    let session = try await loaded("sync_check.mp4", software)
    try await session.play()
    for _ in 0..<200 {
      let counts = await session.decodingStatistics.video
      if (counts?.decodedFrames ?? 0) > 5 {
        let status = await session.videoDecoderStatus
        guard case .software = status else { return XCTFail("\(status)") }
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("no pictures were decoded")
  }

  // ── Threads ─────────────────────────────────────────

  func testTheThreadsAskedForAreTheThreadsSoftwareDecodingRunsOn() async throws {
    let session = try await loaded("sync_check.mp4", .init(preference: .software, softwareThreadCount: 4))
    let status = await session.videoDecoderStatus
    XCTAssertEqual(status, .software(threads: 4))
  }

  func testAThreadCountOutsideTheChoicesIsBroughtToOne() async throws {
    let many = try await loaded("sync_check.mp4", .init(preference: .software, softwareThreadCount: 500))
    let capped = await many.videoDecoderStatus
    XCTAssertEqual(capped, .software(threads: 16))
    let none = try await loaded("sync_check.mp4", .init(preference: .software, softwareThreadCount: 0))
    let raised = await none.videoDecoderStatus
    XCTAssertEqual(raised, .software(threads: 1))
    let between = try await loaded("sync_check.mp4", .init(preference: .software, softwareThreadCount: 7))
    let lowered = await between.videoDecoderStatus
    XCTAssertEqual(lowered, .software(threads: 6))
  }

  /// Hardware that cannot decode a video leaves it to software, on the
  /// threads asked for: the count is for software decoding wherever it is.
  func testThreadsAlsoApplyWhereHardwarePreferredButCannotDecode() async throws {
    let session = try await loaded("b_frames.mkv", .init(preference: .hardware, softwareThreadCount: 2))
    let status = await session.videoDecoderStatus
    XCTAssertEqual(status, .software(threads: 2))
  }

  func testThreadsAreIgnoredWhereHardwareDecodes() async throws {
    try requireHardwareH264()
    let session = try await loaded("sync_check.mp4", .init(preference: .hardware, softwareThreadCount: 4))
    let status = await session.videoDecoderStatus
    XCTAssertEqual(status, .hardware)
  }

  // ── The choice is kept ──────────────────────────────

  /// iOS takes the hardware decoder from an app in the background; what the
  /// app gets on its return is a decoder made again.
  func testSoftwareAndThreadsSurviveRenewing() async throws {
    let configuration = UmbelVideoDecoderConfiguration(preference: .software, softwareThreadCount: 4)
    for mode in [UmbelVideoDecodingMode.synchronous, .asynchronous] {
      let (demux, track) = try await opened("sync_check.mp4")
      let source = try await VideoRoute.session(
        for: track, demux: demux, renderer: PlainRenderer(), mode: mode, decoder: configuration)
      addTeardownBlock { await source.close() }
      try await source.renew()
      let status = await source.decoderStatus
      XCTAssertEqual(status, .software(threads: 4), "\(mode)")
    }
  }

  func testHardwarePreferenceAndTheCountSurviveRenewingToo() async throws {
    let (demux, track) = try await opened("b_frames.mkv")
    let source = try await VideoRoute.session(
      for: track, demux: demux, renderer: PlainRenderer(),
      decoder: .init(preference: .hardware, softwareThreadCount: 2))
    addTeardownBlock { await source.close() }
    try await source.renew()
    let status = await source.decoderStatus
    XCTAssertEqual(status, .software(threads: 2))
  }

  /// A playlist moving on to content encoded otherwise gets a decoder of
  /// its own: made as the first was.
  func testSoftwareAndThreadsSurviveAChangeOfParameters() async throws {
    try requireHardwareH264()
    let (first, firstTrack) = try await opened("b_frames.mkv")  // MPEG-4 Part 2
    let source = try await VideoRoute.session(
      for: firstTrack, demux: first, renderer: PlainRenderer(),
      decoder: .init(preference: .software, softwareThreadCount: 4))
    addTeardownBlock { await source.close() }
    let decoding = try XCTUnwrap(source as? VideoDecodeSession)

    let (other, otherTrack) = try await opened("sync_check.mp4")  // H.264, which hardware decodes
    let parameters = await other.codecParameters(for: otherTrack.id)
    var frames = 0
    while frames == 0, var packet = try await other.nextPacket() {
      guard packet.trackID == otherTrack.id else { continue }
      packet.decoderParameters = parameters
      frames += try await decoding.decode(packet).count
    }
    let rebuilt = await decoding.rebuildCount
    let status = await decoding.decoderStatus
    XCTAssertEqual(rebuilt, 1)
    XCTAssertEqual(status, .software(threads: 4), "not the hardware it could have had, nor FFmpeg's pick")
  }

  /// DV P8.1 shown by the system, until the system refuses the stream: the
  /// base layer is then decoded here, as the session was asked to.
  func testTheBaseLayerFallbackIsDecodedAsAsked() async throws {
    let (demux, track) = try await opened("dv_p81.mp4")
    let source = try await VideoRoute.session(
      for: track, demux: demux, renderer: SystemShowingRenderer(showsDV: false, showsP81: true),
      decoder: .init(preference: .software, softwareThreadCount: 2))
    addTeardownBlock { await source.close() }
    let path = try XCTUnwrap(source as? VideoPath)
    let recovered = try await path.recoverDisplayFailure(UmbelError.videoRenderUnavailable(reason: "refused"))
    XCTAssertTrue(recovered)
    let status = await path.decoderStatus
    XCTAssertEqual(status, .software(threads: 2))
  }

  /// Whether this machine's hardware decodes a stream: VideoToolbox decides
  /// that when it first sees the stream, and not alike on every machine.
  private func hardwareDecodes(_ name: String) async throws -> Bool {
    let (demux, track) = try await opened(name)
    let decoder = try await demux.makeVideoDecoder(for: track.id)
    defer { decoder.close() }
    var number: Int64 = 0
    while let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      number += 1
      let frames = try decoder.decode(FFmpegPacket(
        streamIndex: 0, data: packet.data, pts: number * 40_000, dts: number * 40_000, duration: 0,
        timeBaseNum: 1, timeBaseDen: 1_000_000, isKeyframe: packet.isKeyframe))
      if let first = frames.first { return first.wasHardwareDecoded }
    }
    return false
  }

  /// Hardware chosen, and the stream refused once it is seen: what decodes is
  /// software, and the status says so rather than what was tried.
  func testHardwareThatRefusesAStreamShowsAsSoftware() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 2, "one core is one thread")
    let accepted = try await hardwareDecodes("h264_16x16.mp4")
    try XCTSkipIf(accepted, "this hardware decodes the stream")
    let (demux, track) = try await opened("h264_16x16.mp4")
    let source = try await VideoRoute.session(for: track, demux: demux, renderer: PlainRenderer())
    addTeardownBlock { await source.close() }
    var frames: [VideoFrame] = []
    while frames.isEmpty, let packet = try await demux.nextPacket() {
      guard packet.trackID == track.id else { continue }
      frames += try await source.decode(packet, hidden: false)
    }
    XCTAssertFalse(frames.isEmpty)
    let status = await source.decoderStatus
    guard case .software(let threads)? = status else { return XCTFail("\(String(describing: status))") }
    XCTAssertGreaterThan(try XCTUnwrap(threads), 1)
  }

  // ── The system's decoding is not touched ────────────

  func testSystemDecodedVideoIsNotAffected() async throws {
    let session = try await loaded(
      "dv_p5.mp4", .init(preference: .software, softwareThreadCount: 2),
      renderer: SystemShowingRenderer(showsDV: true))
    let status = await session.videoDecoderStatus
    let decoding = await session.videoDecodingStatus
    XCTAssertEqual(status, .systemManaged)
    XCTAssertEqual(decoding, .systemManaged)
  }

  func testSystemPixelsAreNotAffected() async throws {
    let session = try await loaded(
      "dv_p81.mp4", software, renderer: SystemShowingRenderer(showsDV: false, showsP81: true))
    let status = await session.videoDecoderStatus
    XCTAssertEqual(status, .systemManaged)
  }

  func testTheSystemRoutesAreTheSameWhateverIsAsked() async throws {
    let (demux, track) = try await opened("dv_p5.mp4")
    let source = try await VideoRoute.session(
      for: track, demux: demux, renderer: SystemShowingRenderer(showsDV: true), decoder: software)
    addTeardownBlock { await source.close() }
    XCTAssertTrue(source is SystemDecodeSession)
    let status = await source.decoderStatus
    XCTAssertNil(status, "nothing here is decoded by us")
  }
}
