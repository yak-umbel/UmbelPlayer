import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import XCTest
@testable import UmbelCore

final class VideoPrecisionTests: XCTestCase {
  func testDeclaredChromaLocationAffectsSamplingCoordinates() async throws {
    let buffer = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(width: 8, height: 4, luma: 128, cb: 128, cr: 128))
    CVPixelBufferLockBaseAddress(buffer, [])
    for row in 0..<2 {
      let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        .advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
      for x in 0..<4 { pixels[x*2] = x % 2 == 0 ? 64 : 192 }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    var frame = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 8, height: 4,
      color: .init(matrix: .bt709, range: .limited))
    frame.chromaLocationCode = 1
    let output = try renderer()
    try await output.prepare(width: 8, height: 4, color: frame.color)
    try await output.enqueue(frame)
    _ = try await output.presentFrame(at: .zero)
    let pixel = try await output.readValue(x: 1, y: 2)
    XCTAssertEqual(pixel.b, 112.0 / 219.0, accuracy: 0.01)
  }
  func testLinearFloatingPointWorkIsNotClippedToIntegerRange() async throws {
    var created: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_128RGBAFloat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created), kCVReturnSuccess)
    let buffer = try XCTUnwrap(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    for row in 0..<4 {
      let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        .advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float.self)
      for x in 0..<4 { pixels[x*4] = -0.05; pixels[x*4+1] = 0.5; pixels[x*4+2] = 1.05; pixels[x*4+3] = 1 }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 4, height: 4,
      color: .init(matrix: .unspecified, range: .full, transferCode: 8))
    let output = try renderer()
    try await output.prepare(width: 4, height: 4, color: frame.color)
    try await output.enqueue(frame)
    _ = try await output.presentFrame(at: .zero)
    let pixel = try await output.readValue(x: 2, y: 2)
    XCTAssertEqual(pixel.r, -0.05, accuracy: 0.000001)
    XCTAssertEqual(pixel.b, 1.05, accuracy: 0.000001)
  }
  func testSixteenBitWorkingOutputKeepsAdjacentCodes() async throws {
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created)
    XCTAssertEqual(status, kCVReturnSuccess)
    let buffer = try XCTUnwrap(created)
    CVPixelBufferLockBaseAddress(buffer, [])
    for row in 0..<4 {
      let y = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        .advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
      let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        .advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
      for x in 0..<4 { y[x] = UInt16(32768 + x); uv[2*x] = 32768; uv[2*x+1] = 32768 }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 4, height: 4,
      color: .init(matrix: .bt709, range: .limited, transferCode: 8))
    let output = try renderer()
    try await output.prepare(width: 4, height: 4, color: frame.color)
    try await output.enqueue(frame)
    _ = try await output.presentFrame(at: .zero)
    let format = await output.targetPixelFormat
    XCTAssertEqual(format, .rgba32Float)
    var previous: Float = -1
    for x in 0..<4 {
      let value = try await output.readValue(x: x, y: 2).g
      XCTAssertGreaterThan(value, previous)
      XCTAssertEqual(value, Float(32768 + x - 4096) / 56064, accuracy: 0.000001)
      previous = value
    }
  }
  private func renderer(range: UmbelDynamicRange = .automatic) throws -> OffscreenVideoRenderer {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    return try OffscreenVideoRenderer(device: device, dynamicRange: range, tolerance: .zero)
  }

  private func picture(code: UInt16, transfer: UmbelTransferFunction = .sdr) throws -> VideoFrame {
    let buffer = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(
      width: 32, height: 32, luma: code, cb: 512, cr: 512))
    return VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 32, height: 32,
      color: .init(matrix: .bt709, range: .limited, transfer: transfer))
  }

  func testAdjacentTenBitSDRCodesRemainDistinctInLinearLight() async throws {
    let renderer = try renderer()
    try await renderer.prepare(width: 32, height: 32, color: .init(matrix: .bt709, range: .limited))
    var samples: [Float] = []
    for code: UInt16 in [500, 501, 502, 503] {
      await renderer.flush()
      try await renderer.enqueue(try picture(code: code))
      _ = try await renderer.presentFrame(at: .zero)
      samples.append(try await renderer.readValue(x: 16, y: 16).g)
    }
    let format = await renderer.targetPixelFormat
    XCTAssertEqual(format, .rgba16Float)
    // BT.709 inverse OETF, independently evaluated from the limited-range signal.
    for (index, code) in [500.0, 501, 502, 503].enumerated() {
      let signal = (code - 64) / 876
      let expected = pow((signal + 0.099) / 1.099, 1 / 0.45)
      XCTAssertEqual(Double(samples[index]), expected, accuracy: 0.0003)
      if index > 0 { XCTAssertGreaterThan(samples[index], samples[index - 1]) }
    }
  }

  func testStandardDynamicRangeDoesNotReduceTenBitToEightBit() async throws {
    let renderer = try renderer(range: .standard)
    let frame = try picture(code: 723, transfer: .pq)
    try await renderer.prepare(width: 32, height: 32, color: frame.color)
    try await renderer.enqueue(frame)
    _ = try await renderer.presentFrame(at: .zero)
    let format = await renderer.targetPixelFormat
    let value = try await renderer.readValue(x: 16, y: 16)
    XCTAssertEqual(format, .rgba16Float)
    XCTAssertLessThanOrEqual(value.g, 1)
    XCTAssertGreaterThan(value.g, 0)
  }
}
