import CoreMedia
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

final class VideoCapabilitiesTests: XCTestCase {
  private final class FixedTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private final class Sink: SampleBufferSink, @unchecked Sendable {
    func enqueue(_ buffer: CMSampleBuffer) {}
    func flush() {}
    var hasFailed: Bool { false }
    var isReadyForMoreMediaData: Bool { true }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name)")
  }

  func testPixelRouteBecomesCapturableOnlyAfterPresentation() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let session = PlaybackSession(source: try UmbelFileSource(url: fixture("hevc10_white.mp4")),
                                  videoRenderer: renderer, hostTime: FixedTime())
    addTeardownBlock { await session.stop() }
    let idle = await session.videoCapabilities
    XCTAssertFalse(idle.canOverrideAspectRatio)
    try await session.load()
    let loaded = await session.videoCapabilities
    XCTAssertTrue(loaded.canAdjustColors)
    XCTAssertTrue(loaded.canOverrideAspectRatio)
    XCTAssertTrue(loaded.canScalePicture)
    XCTAssertEqual(loaded.snapshot, .noFrame)
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let shown = await session.videoCapabilities
    XCTAssertEqual(shown.snapshot, .available)
    await session.pause()
    _ = try await session.snapshot()
    try await session.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
    let seeking = await session.videoCapabilities
    XCTAssertEqual(seeking.snapshot, .noFrame)
    await session.stop()
    let stopped = await session.videoCapabilities
    XCTAssertFalse(stopped.canOverrideAspectRatio)
    XCTAssertNotEqual(stopped.snapshot, .available)
  }

  func testSwitchingOutputsDoesNotAdvertiseThePreviousOutputsFrame() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
    let main = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let other = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let renderer = SwitchingVideoRenderer(main: main, pictureInPicture: other)
    let pixels = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(
      width: 8, height: 8, luma: 235, cb: 128, cr: 128))
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: pixels, width: 8, height: 8,
                           color: VideoColorDescription(matrix: .bt709, range: .limited))
    try await renderer.prepare(width: 8, height: 8, color: frame.color)
    try await renderer.enqueue(frame)
    _ = try await renderer.presentFrame(at: .zero)
    let before = await renderer.videoCapabilities
    XCTAssertEqual(before.snapshot, .available)
    await renderer.show(.pictureInPicture)
    let switched = await renderer.videoCapabilities
    XCTAssertEqual(switched.snapshot, .noFrame)
    _ = try await renderer.presentFrame(at: .zero)
    let shown = await renderer.videoCapabilities
    XCTAssertEqual(shown.snapshot, .available)
  }

  func testSystemRouteReportsLimitsBeforeTheFirstFrame() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
    let main = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let system = try SampleBufferVideoRenderer(sink: Sink(), device: device,
                                               tolerance: .zero, systemShowsDV: true)
    let renderer = SwitchingVideoRenderer(main: main, pictureInPicture: system)
    let session = PlaybackSession(source: try UmbelFileSource(url: fixture("dv_p5.mp4")),
                                  videoRenderer: renderer, hostTime: FixedTime())
    addTeardownBlock { await session.stop() }
    try await session.load()
    let capabilities = await session.videoCapabilities
    XCTAssertFalse(capabilities.canAdjustColors)
    await session.setVideoAdjustments(.init(brightness: 0.5))
    let retainedAdjustments = await session.videoAdjustments
    XCTAssertEqual(retainedAdjustments, .init(brightness: 0.5))
    XCTAssertFalse(capabilities.canOverrideAspectRatio)
    XCTAssertTrue(capabilities.canScalePicture)
    XCTAssertEqual(capabilities.snapshot, .unsupported(.systemDisplay))
    await session.setAspectRatio(2)
    let stillUnsupported = await session.videoCapabilities
    XCTAssertFalse(stillUnsupported.canOverrideAspectRatio)
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await session.pause()
    let paused = await session.videoCapabilities
    XCTAssertEqual(paused.snapshot, .unsupported(.systemDisplay))
  }

  func testPixelSampleBufferRouteDoesNotClaimViewportCropping() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
    let renderer = try SampleBufferVideoRenderer(sink: Sink(), device: device, tolerance: .zero)
    let capabilities = await renderer.videoCapabilities
    XCTAssertTrue(capabilities.canOverrideAspectRatio)
    XCTAssertFalse(capabilities.canScalePicture, "pixel buffers are handed to the system as whole pictures")
  }
}
