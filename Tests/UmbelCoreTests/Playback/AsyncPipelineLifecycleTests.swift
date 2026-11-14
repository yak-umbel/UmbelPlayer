import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private actor DrainFailingVideoSource: VideoFrameSource {
  var skipsNonReference = false
  func decode(_ packet: DemuxPacket, hidden: Bool) async throws -> [VideoFrame] { [] }
  func drain() async throws -> [VideoFrame] {
    throw UmbelError.videoRenderUnavailable(reason: "final decode failed")
  }
  func flush() async {}
  func renew() async throws {}
  func close() async {}
  func setSkipsNonReference(_ skips: Bool) async { skipsNonReference = skips }
}

private actor ImmediateVideoRenderer: VideoRenderer {
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) async throws {}
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { 0 }
  var totalDroppedFrames: Int { 0 }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

final class AsyncPipelineLifecycleTests: XCTestCase {
  func testFinalDecodeFailureIsReportedInsteadOfEnded() async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync_check.mp4")
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let source = DrainFailingVideoSource()
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: nil, videoRenderer: ImmediateVideoRenderer(),
      clock: PresentationClock(hostTime: SystemHostTimeSource()),
      cache: PacketCache(configuration: .init(), measuredTrack: nil))
    await pipeline.updateRouting(PacketRouting(
      audioID: nil, audioSession: nil, videoID: track.id, videoSession: source, generation: 0))
    addTeardownBlock { await pipeline.stop() }
    await pipeline.start()
    for _ in 0..<200 {
      if await pipeline.terminal != nil { break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let phase = await pipeline.terminal
    let failure = await pipeline.failureReason
    XCTAssertEqual(phase, .failed)
    XCTAssertEqual(failure?.errorDescription, "video rendering unavailable: final decode failed")
  }
}
