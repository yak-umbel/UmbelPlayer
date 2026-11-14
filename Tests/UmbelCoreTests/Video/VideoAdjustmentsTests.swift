import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

final class VideoAdjustmentsTests: XCTestCase {
  private func sRGBByte(from signal: UInt8, toneMapped: Bool = false) -> Int {
    let e = Double(signal) / 255
    let light = toneMapped ? pow(e, 2.4) : e < 0.081 ? e / 4.5 : pow((e + 0.099) / 1.099, 1 / 0.45)
    let encoded = light <= 0.0031308 ? light * 12.92 : 1.055 * pow(light, 1 / 2.4) - 0.055
    return Int((encoded * 255).rounded())
  }
  private final class HeldTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func device() throws -> MTLDevice {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    return device
  }

  private func frame(
    luma: UInt8 = 126, cb: UInt8 = 128, cr: UInt8 = 128
  ) throws -> VideoFrame {
    let buffer = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(
      width: 64, height: 64, luma: luma, cb: cb, cr: cr))
    return VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
                      color: VideoColorDescription(matrix: .bt709, range: .limited))
  }

  private func hdrFrame(
    _ transfer: UmbelTransferFunction, luma: UInt16, cb: UInt16 = 512, cr: UInt16 = 512
  ) throws -> VideoFrame {
    let buffer = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(
      width: 64, height: 64, luma: luma, cb: cb, cr: cr))
    return VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
                      color: VideoColorDescription(matrix: .bt2020, range: .limited,
                                                   transfer: transfer, primaries: .bt2020))
  }

  private func draw(_ frame: VideoFrame) async throws -> OffscreenVideoRenderer {
    let renderer = try OffscreenVideoRenderer(device: device(), tolerance: .zero)
    try await renderer.prepare(width: 64, height: 64, color: frame.color)
    try await renderer.enqueue(frame)
    _ = try await renderer.presentFrame(at: .zero)
    return renderer
  }

  // Catches a setter that fails to mark the displayed picture dirty or fails to reset.
  func testBrightnessContrastAndResetRedrawThePausedPicture() async throws {
    let renderer = try await draw(frame(luma: 71))
    let before = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertEqual(Int(before.r), 64, accuracy: 1)
    await renderer.setVideoAdjustments(.init(brightness: 0.25))
    _ = try await renderer.presentFrame(at: .zero)
    let brighter = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertEqual(Int(brighter.r), 128, accuracy: 1)
    await renderer.setVideoAdjustments(.init(contrast: 2))
    _ = try await renderer.presentFrame(at: .zero)
    let contrasted = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertLessThan(contrasted.r, 2)
    await renderer.setVideoAdjustments(.init())
    _ = try await renderer.presentFrame(at: .zero)
    let reset = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertEqual(reset.r, before.r)
    XCTAssertEqual(reset.g, before.g)
    XCTAssertEqual(reset.b, before.b)
  }

  func testSaturationZeroProducesBT709Luminance() async throws {
    let renderer = try await draw(frame(luma: 63, cb: 102, cr: 240))
    await renderer.setVideoAdjustments(.init(saturation: 0))
    _ = try await renderer.presentFrame(at: .zero)
    let pixel = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertEqual(Int(pixel.r), 55, accuracy: 1)
    XCTAssertEqual(pixel.r, pixel.g)
    XCTAssertEqual(pixel.r, pixel.b)
  }

  func testHDRBrightnessUsesReferenceWhiteWithoutClippingHeadroom() async throws {
    for (transfer, code, expected) in [(UmbelTransferFunction.pq, 723, 10.5495), (.hlg, 721, 3.9745)] {
      let renderer = try await draw(hdrFrame(transfer, luma: UInt16(code)))
      await renderer.setVideoAdjustments(.init(brightness: 0.25))
      _ = try await renderer.presentFrame(at: .zero)
      let value = try await renderer.readValue(x: 32, y: 32)
      XCTAssertEqual(value.r, Float(expected), accuracy: 0.025, "\(transfer)")
    }
  }

  func testContrastZeroUsesHalfOutputReferenceWhite() async throws {
    for (transfer, white) in [(UmbelTransferFunction.pq, 2.03), (.hlg, 3.1796), (.sdr, 1)] {
      let picture = transfer == .sdr ? try frame() : try hdrFrame(transfer, luma: 723)
      let renderer = try await draw(picture)
      await renderer.setVideoAdjustments(.init(brightness: 0.1, contrast: 0))
      _ = try await renderer.presentFrame(at: .zero)
      let value = try await renderer.readValue(x: 32, y: 32)
      XCTAssertEqual(value.r, Float(white * 0.6), accuracy: 0.005, "\(transfer)")
    }
  }

  func testHDRSaturationUsesBT2020OutputLuminance() async throws {
    let renderer = try await draw(hdrFrame(.pq, luma: 600, cb: 450, cr: 600))
    let color = try await renderer.readValue(x: 32, y: 32)
    let luminance = color.r * 0.2627 + color.g * 0.6780 + color.b * 0.0593
    await renderer.setVideoAdjustments(.init(saturation: 0))
    _ = try await renderer.presentFrame(at: .zero)
    let grey = try await renderer.readValue(x: 32, y: 32)
    XCTAssertEqual(grey.r, luminance, accuracy: 0.005)
    XCTAssertEqual(grey.g, grey.r)
    XCTAssertEqual(grey.b, grey.r)
  }

  func testOpaqueSubtitlesKeepTheirPixelsAfterVideoAdjustment() async throws {
    let renderer = try await draw(frame())
    let bytes = Data([[UInt8]](repeating: [0, 0, 255, 255], count: 4).flatMap { $0 })
    let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
    let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue), provider: provider, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent))
    await renderer.setSubtitles([UmbelSubtitleBitmap(
      image: image, frame: CGRect(x: 16, y: 16, width: 32, height: 32))])
    await renderer.setVideoAdjustments(.init(brightness: -1, contrast: 0, saturation: 0))
    _ = try await renderer.presentFrame(at: .zero)
    let subtitle = try await renderer.readPixel(x: 32, y: 32)
    let video = try await renderer.readPixel(x: 4, y: 4)
    XCTAssertEqual(subtitle.r, 255)
    XCTAssertEqual(subtitle.g, 0)
    XCTAssertEqual(video.r, 0)
  }

  func testSwitchingAndFlushRetainAdjustments() async throws {
    let main = try OffscreenVideoRenderer(device: device(), tolerance: .zero)
    let other = try OffscreenVideoRenderer(device: device(), tolerance: .zero)
    let renderer = SwitchingVideoRenderer(main: main, pictureInPicture: other)
    let picture = try frame(luma: 71)
    await renderer.setVideoAdjustments(.init(brightness: 0.25))
    try await renderer.prepare(width: 64, height: 64, color: picture.color)
    try await renderer.enqueue(picture)
    _ = try await renderer.presentFrame(at: .zero)
    await renderer.show(.pictureInPicture)
    _ = try await renderer.presentFrame(at: .zero)
    let switched = try await other.readPixel(x: 32, y: 32)
    XCTAssertEqual(Int(switched.r), 128, accuracy: 1)
    await renderer.flush()
    try await renderer.enqueue(picture)
    _ = try await renderer.presentFrame(at: .zero)
    let sought = try await other.readPixel(x: 32, y: 32)
    XCTAssertEqual(sought.r, switched.r)
  }

  func testSessionPausedRedrawAndSnapshotAgreeAndSeekRetainsSettings() async throws {
    let renderer = try OffscreenVideoRenderer(device: device(), tolerance: .zero)
    let source = try UmbelFileSource(url: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hevc10_white.mp4"))
    let session = PlaybackSession(source: source, videoRenderer: renderer, hostTime: HeldTime())
    addTeardownBlock { await session.stop() }
    await session.setVideoAdjustments(.init(brightness: -0.25))
    try await session.load()
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await session.pause()
    await session.setVideoAdjustments(.init(contrast: 0))
    let paused = try await renderer.readPixel(x: 4, y: 4)
    XCTAssertEqual(Int(paused.r), 128, accuracy: 1)
    let image = try await session.snapshot(includingSubtitles: false)
    let data = try XCTUnwrap(image.dataProvider?.data)
    let bytes = [UInt8](data as Data)
    XCTAssertEqual(Int(bytes[(4 * image.width + 4) * 4 + 2]), sRGBByte(from: paused.r), accuracy: 2,
                   "half-float playback and eight-bit export may round on opposite sides of a code boundary")
    try await session.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
    let retained = await session.videoAdjustments
    XCTAssertEqual(retained, .init(contrast: 0))
    await session.setVideoAdjustments(.init())
    let neutral = await session.videoAdjustments
    XCTAssertEqual(neutral, .init())
  }
  func testInvalidInputsAreNeutralAndFiniteInputsClampBeforeGPUUse() async throws {
    let invalid = UmbelVideoAdjustments(brightness: .nan, contrast: .infinity, saturation: -.infinity)
    XCTAssertEqual(invalid, .init())
    let bounded = UmbelVideoAdjustments(brightness: 3, contrast: -3, saturation: 7)
    XCTAssertEqual(bounded.brightness, 1)
    XCTAssertEqual(bounded.contrast, 0)
    XCTAssertEqual(bounded.saturation, 2)
    let opposite = UmbelVideoAdjustments(brightness: -3, contrast: 7, saturation: -3)
    XCTAssertEqual(opposite.brightness, -1)
    XCTAssertEqual(opposite.contrast, 2)
    XCTAssertEqual(opposite.saturation, 0)
    let renderer = try await draw(frame(luma: 71))
    await renderer.setVideoAdjustments(invalid)
    _ = try await renderer.presentFrame(at: .zero)
    let neutral = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertEqual(Int(neutral.r), 64, accuracy: 1)
    await renderer.setVideoAdjustments(bounded)
    _ = try await renderer.presentFrame(at: .zero)
    let white = try await renderer.readPixel(x: 32, y: 32)
    XCTAssertEqual(white.r, 255)
  }

  func testHDRResetExactlyRestoresExistingOutput() async throws {
    for transfer in [UmbelTransferFunction.pq, .hlg] {
      let renderer = try await draw(hdrFrame(transfer, luma: 600, cb: 450, cr: 600))
      let before = try await renderer.readValue(x: 32, y: 32)
      await renderer.setVideoAdjustments(.init(brightness: 0.7, contrast: 1.4, saturation: 0.5))
      _ = try await renderer.presentFrame(at: .zero)
      await renderer.setVideoAdjustments(.init())
      _ = try await renderer.presentFrame(at: .zero)
      let reset = try await renderer.readValue(x: 32, y: 32)
      XCTAssertEqual(reset.r, before.r)
      XCTAssertEqual(reset.g, before.g)
      XCTAssertEqual(reset.b, before.b)
    }
  }

  func testToneMappedSnapshotUsesSameSDRAdjustmentAndNeutralDefault() async throws {
    let gpu = try device()
    let picture = try hdrFrame(.pq, luma: 600, cb: 450, cr: 600)
    let renderer = try OffscreenVideoRenderer(device: gpu, dynamicRange: .standard, tolerance: .zero)
    try await renderer.prepare(width: 64, height: 64, color: picture.color)
    try await renderer.enqueue(picture)
    _ = try await renderer.presentFrame(at: .zero)
    let neutral = try await renderer.readPixel(x: 32, y: 32)
    let defaultImage = try FrameSnapshot.image(of: picture, size: CGSize(width: 64, height: 64),
                                              subtitles: [], device: gpu)
    let defaultData = [UInt8](try XCTUnwrap(defaultImage.dataProvider?.data) as Data)
    XCTAssertEqual(Int(defaultData[2]), sRGBByte(from: neutral.r, toneMapped: true), accuracy: 2)
    let adjustments = UmbelVideoAdjustments(brightness: -0.1, contrast: 1.3, saturation: 0)
    await renderer.setVideoAdjustments(adjustments)
    _ = try await renderer.presentFrame(at: .zero)
    let adjusted = try await renderer.readPixel(x: 32, y: 32)
    let image = try FrameSnapshot.image(of: picture, size: CGSize(width: 64, height: 64),
                                       subtitles: [], device: gpu, adjustments: adjustments)
    let data = [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
    XCTAssertEqual(Int(data[2]), sRGBByte(from: adjusted.r, toneMapped: true), accuracy: 2)
    XCTAssertEqual(adjusted.r, adjusted.g)
    XCTAssertEqual(adjusted.r, adjusted.b)
    XCTAssertNotEqual(adjusted.r, neutral.r)
  }

}

