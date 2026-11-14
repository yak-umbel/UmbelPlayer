import CoreMedia
import CoreVideo
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

final class VideoGamutTests: XCTestCase {
  func testSRGBSubtitleKeepsItsColorOnTaggedSDROutputsAndSnapshots() async throws {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let buffer = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(width: 8, height: 4, luma: 16, cb: 128, cr: 128))
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 8, height: 4,
      color: .init(matrix: .bt709, range: .limited))
    let bytes = Data([UInt8](repeating: 128, count: 3) + [255])
    let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
    let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let subtitle = UmbelSubtitleBitmap(image: image, frame: CGRect(x: 0, y: 0, width: 8, height: 4))
    let output = try OffscreenVideoRenderer(device: gpu, tolerance: .zero)
    try await output.prepare(width: 8, height: 4, color: frame.color)
    await output.setSubtitles([subtitle])
    try await output.enqueue(frame)
    _ = try await output.presentFrame(at: .zero)
    let pixel = try await output.readPixel(x: 2, y: 2)
    XCTAssertEqual(Int(pixel.g), 115, accuracy: 1, "sRGB code 128 encoded for the BT.709 target")
    let snapshot = try FrameSnapshot.image(of: frame, size: CGSize(width: 8, height: 4), subtitles: [subtitle], device: gpu)
    let actual = [UInt8](try XCTUnwrap(snapshot.dataProvider?.data) as Data)
    XCTAssertEqual(Int(actual[1]), 128, accuracy: 1)
  }
  func testDisplayP3RedIsConvertedIntoTaggedWorkingPrimaries() async throws {
    guard let gpu = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    var created: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_64RGBALE,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created), kCVReturnSuccess)
    let buffer = try XCTUnwrap(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    for row in 0..<4 {
      let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt16.self)
      for x in 0..<4 { pixels[x*4] = 65535; pixels[x*4+1] = 0; pixels[x*4+2] = 0; pixels[x*4+3] = 65535 }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let color = try VideoColorDescription.from(colorspace: 0, range: 2, transfer: 8, primaries: 12)
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 4, height: 4, color: color)
    let output = try OffscreenVideoRenderer(device: gpu, tolerance: .zero)
    try await output.prepare(width: 4, height: 4, color: color)
    try await output.enqueue(frame)
    _ = try await output.presentFrame(at: .zero)
    let pixel = try await output.readValue(x: 2, y: 2)
    // Display P3 D65 to BT.2020 D65, derived from the standardized xy primaries.
    XCTAssertEqual(pixel.r, 0.753833, accuracy: 0.00001)
    XCTAssertEqual(pixel.g, 0.045744, accuracy: 0.00001)
    XCTAssertEqual(pixel.b, -0.001210, accuracy: 0.00001)
  }
}
