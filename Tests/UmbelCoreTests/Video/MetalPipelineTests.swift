import CoreVideo
import Metal
import XCTest
@testable import UmbelCore

final class MetalPipelineTests: XCTestCase {
  /// CI may have no graphics device. A skip **says why** — a test passing
  /// silently is worse than none, making people think there is a defence.
  private func makePipelineOrSkip() throws -> MetalPipeline {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device here; rendering tests skipped")
    }
    return try MetalPipeline(device: device)
  }

  func testShaderCompilesAndPipelineIsCreated() throws {
    let pipeline = try makePipelineOrSkip()
    XCTAssertNotNil(pipeline.device)
  }

  func testMakesTwoTexturesFromBiplanarBuffer() throws {
    let pipeline = try makePipelineOrSkip()
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 64, height: 32, luma: 128, cb: 128, cr: 128))
    let textures = try pipeline.makeTextures(from: buffer)

    XCTAssertEqual(textures.luma.width, 64)
    XCTAssertEqual(textures.luma.height, 32)
    XCTAssertEqual(textures.luma.pixelFormat, .r8Unorm, "the luma plane is one 8-bit channel")

    XCTAssertEqual(textures.chroma.width, 32, "the chroma plane is half as wide")
    XCTAssertEqual(textures.chroma.height, 16, "the chroma plane is half as tall")
    XCTAssertEqual(textures.chroma.pixelFormat, .rg8Unorm, "the chroma plane is two 8-bit channels")
  }

  func testLimitedRangeUniformsDifferFromFullRange() {
    let limited = ColorUniforms(
      for: VideoColorDescription(matrix: .bt709, range: .limited), matrix: .bt709, isTenBit: false)
    let full = ColorUniforms(
      for: VideoColorDescription(matrix: .bt709, range: .full), matrix: .bt709, isTenBit: false)
    XCTAssertGreaterThan(limited.lumaOffset, full.lumaOffset,
                         "limited-range luma has 16/255 taken off first")
    XCTAssertGreaterThan(limited.lumaScale, full.lumaScale,
                         "limited range stretches 16–235 to 0–1")
  }

  func testFullRangeUniformsAreIdentityOnLuma() {
    let full = ColorUniforms(
      for: VideoColorDescription(matrix: .bt709, range: .full), matrix: .bt709, isTenBit: false)
    XCTAssertEqual(full.lumaOffset, 0, accuracy: 0.0001)
    XCTAssertEqual(full.lumaScale, 1, accuracy: 0.0001)
  }

  /// A completed frame must not keep a bounded output pool's only surface busy.
  func testCompletedTexturesAllowAPooledBufferToBeReused() throws {
    let pipeline = try makePipelineOrSkip()
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelBufferWidthKey: 128, kCVPixelBufferHeightKey: 64,
      kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var created: CVPixelBufferPool?
    XCTAssertEqual(CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created), kCVReturnSuccess)
    let pool = try XCTUnwrap(created)
    let budget = [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary
    try autoreleasepool {
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, budget, &buffer), kCVReturnSuccess)
      _ = try pipeline.makeTextures(from: XCTUnwrap(buffer))
    }
    pipeline.releaseRetainedTextures()
    var reused: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, budget, &reused),
                   kCVReturnSuccess, "completed texture views must let the bounded pool reuse its surface")
  }
}
