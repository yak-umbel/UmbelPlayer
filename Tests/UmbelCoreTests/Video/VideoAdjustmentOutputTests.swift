import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import QuartzCore
import XCTest
@testable import UmbelCore

final class VideoAdjustmentOutputTests: XCTestCase {
  private final class Sink: SampleBufferSink, @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: [UInt8] = []
    var isReadyForMoreMediaData: Bool { true }
    var hasFailed: Bool { false }
    var redPixels: [UInt8] {
      lock.lock()
      defer { lock.unlock() }
      return pixels
    }
    func enqueue(_ buffer: CMSampleBuffer) {
      guard let image = CMSampleBufferGetImageBuffer(buffer) else { return }
      CVPixelBufferLockBaseAddress(image, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(image) else { return }
      let red = base.assumingMemoryBound(to: UInt8.self)[2]
      lock.lock()
      pixels.append(red)
      lock.unlock()
    }
    func flush() {}
  }

  // A pre-existing custom conformer need not implement the new setter or capability.
  private actor CustomRenderer: VideoRenderer {
    func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) {}
    func enqueue(_ frame: VideoFrame) {}
    func presentFrame(at time: CMTime) -> PresentedFrame? { nil }
    func flush() {}
    var queueDepth: Int { 0 }
    var totalDroppedFrames: Int { 0 }
    var subtitleCanvasSize: CGSize { .zero }
    func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) {}
    func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) {}
  }

  private func device() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    return device
  }

  private func frame() throws -> VideoFrame {
    let pixels = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(
      width: 8, height: 8, luma: 71, cb: 128, cr: 128))
    return VideoFrame(presentationTime: .zero, pixelBuffer: pixels, width: 8, height: 8,
                      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  func testSampleBuffersReceiveAdjustedPixelsAndPausedReset() async throws {
    let sink = Sink()
    let renderer = try SampleBufferVideoRenderer(sink: sink, device: device(), tolerance: .zero)
    let picture = try frame()
    await renderer.setVideoAdjustments(.init(brightness: 0.25))
    try await renderer.prepare(width: 8, height: 8, color: picture.color)
    try await renderer.enqueue(picture)
    _ = try await renderer.presentFrame(at: .zero)
    for _ in 0..<100 where sink.redPixels.isEmpty {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(Int(try XCTUnwrap(sink.redPixels.first)), 128, accuracy: 1)
    await renderer.setVideoAdjustments(.init())
    _ = try await renderer.presentFrame(at: .zero)
    for _ in 0..<100 where sink.redPixels.count < 2 {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(sink.redPixels.count, 2)
    XCTAssertEqual(Int(try XCTUnwrap(sink.redPixels.last)), 64, accuracy: 1)
  }

  func testSystemRouteRetainsSettingsForLaterPixelRoute() async throws {
    let main = try OffscreenVideoRenderer(device: device(), tolerance: .zero)
    let system = try SampleBufferVideoRenderer(sink: Sink(), device: device(), tolerance: .zero)
    let renderer = SwitchingVideoRenderer(main: main, pictureInPicture: system)
    await renderer.setSystemVideoRoute(true)
    let compressed = await renderer.videoCapabilities
    XCTAssertFalse(compressed.canAdjustColors)
    await renderer.setVideoAdjustments(.init(brightness: 0.25))
    await renderer.setSystemVideoRoute(false)
    let pixels = await renderer.videoCapabilities
    XCTAssertTrue(pixels.canAdjustColors)
    let picture = try frame()
    try await renderer.prepare(width: 8, height: 8, color: picture.color)
    try await renderer.enqueue(picture)
    _ = try await renderer.presentFrame(at: .zero)
    let adjusted = try await main.readPixel(x: 4, y: 4)
    XCTAssertEqual(Int(adjusted.r), 128, accuracy: 1)
  }

  func testCustomRendererAndOldCapabilityInitializerDefaultToUnsupported() async {
    let renderer = CustomRenderer()
    await renderer.setVideoAdjustments(.init(brightness: 1))
    let capability = await renderer.videoCapabilities
    XCTAssertFalse(capability.canAdjustColors)
    XCTAssertFalse(UmbelVideoCapabilities(canOverrideAspectRatio: true, canScalePicture: true,
                                         snapshot: .noFrame).canAdjustColors)
  }

  @MainActor
  func testMetalLayerAndSampleBufferPixelPathsAdvertiseSupport() async throws {
    let metal = try MetalVideoRenderer(layer: CAMetalLayer(), device: device(), tolerance: .zero)
    let sample = try SampleBufferVideoRenderer(sink: Sink(), device: device(), tolerance: .zero)
    let metalCapabilities = await metal.videoCapabilities
    let sampleCapabilities = await sample.videoCapabilities
    XCTAssertTrue(metalCapabilities.canAdjustColors)
    XCTAssertTrue(sampleCapabilities.canAdjustColors)
    await metal.setOverlaysSystemPicture(true)
    let overlayCapabilities = await metal.videoCapabilities
    XCTAssertFalse(overlayCapabilities.canAdjustColors)
  }
}
