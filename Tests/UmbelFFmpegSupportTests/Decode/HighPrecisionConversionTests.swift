import CoreVideo
import FFmpeg
import XCTest
@testable import UmbelFFmpegSupport

final class HighPrecisionConversionTests: XCTestCase {
  func testDeep420ChromaIsInterpolatedAtItsDeclaredLocation() throws {
    let decoder = try decoder()
    defer { decoder.close() }
    var allocated = av_frame_alloc()
    let frame = try XCTUnwrap(allocated)
    defer { av_frame_free(&allocated) }
    frame.pointee.format = AV_PIX_FMT_YUV420P12LE.rawValue
    frame.pointee.width = 8; frame.pointee.height = 4
    frame.pointee.chroma_location = AVCHROMA_LOC_LEFT
    frame.pointee.color_range = AVCOL_RANGE_MPEG
    XCTAssertEqual(av_frame_get_buffer(frame, 32), 0)
    for (index, (component, stride)) in zip([frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2],
      [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2]).enumerated() {
      let base = try XCTUnwrap(component)
      for row in 0..<(index == 0 ? 4 : 2) {
        let pixels = UnsafeMutableRawPointer(base + row * Int(stride)).assumingMemoryBound(to: UInt16.self)
        for x in 0..<(index == 0 ? 8 : 4) { pixels[x] = x % 2 == 0 ? 1024 : 3072 }
      }
    }
    let buffer = try decoder.copyIntoPixelBuffer(frame, width: 8, height: 4)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
    XCTAssertEqual([pixels[0], pixels[2], pixels[4]], [16384, 32768, 49152])
  }
  func testRGB48DoesNotRoundTripThroughSubsampledYUV() throws {
    let decoder = try decoder()
    defer { decoder.close() }
    var allocated = av_frame_alloc()
    let frame = try XCTUnwrap(allocated)
    defer { av_frame_free(&allocated) }
    frame.pointee.format = AV_PIX_FMT_RGB48LE.rawValue
    frame.pointee.width = 8
    frame.pointee.height = 4
    frame.pointee.color_range = AVCOL_RANGE_JPEG
    XCTAssertEqual(av_frame_get_buffer(frame, 32), 0)
    let base = try XCTUnwrap(frame.pointee.data.0)
    for row in 0..<4 {
      let words = UnsafeMutableRawPointer(base + row * Int(frame.pointee.linesize.0)).assumingMemoryBound(to: UInt16.self)
      for x in 0..<8 { words[x*3] = 12345; words[x*3+1] = 23456; words[x*3+2] = 34567 }
    }
    let buffer = try decoder.copyIntoPixelBuffer(frame, width: 8, height: 4)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_64RGBALE)
    guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_64RGBALE else { return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt16.self)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels, count: 3)), [12345, 23456, 34567])
  }
  private func decoder() throws -> FFmpegVideoDecoder {
    let parameters = try XCTUnwrap(avcodec_parameters_alloc())
    defer { var p: UnsafeMutablePointer<AVCodecParameters>? = parameters; avcodec_parameters_free(&p) }
    parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
    parameters.pointee.codec_id = AV_CODEC_ID_HEVC
    parameters.pointee.width = 8
    parameters.pointee.height = 4
    return try FFmpegVideoDecoder(parameters: parameters, timeBaseNum: 1, timeBaseDen: 25,
      containerAspect: AVRational(num: 1, den: 1), preferHardware: false)
  }

  func testTwelveBitLowCodesAreNotDiscardedBeforeRendering() throws {
    let decoder = try decoder()
    defer { decoder.close() }
    var allocated = av_frame_alloc()
    let frame = try XCTUnwrap(allocated)
    defer { av_frame_free(&allocated) }
    frame.pointee.format = AV_PIX_FMT_YUV444P12LE.rawValue
    frame.pointee.width = 8
    frame.pointee.height = 4
    frame.pointee.color_range = AVCOL_RANGE_MPEG
    XCTAssertEqual(av_frame_get_buffer(frame, 32), 0)
    for (plane, stride) in zip([frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2],
                              [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2]) {
      let base = try XCTUnwrap(plane)
      for row in 0..<4 {
        let pixels = UnsafeMutableRawPointer(base + row * Int(stride)).assumingMemoryBound(to: UInt16.self)
        for column in 0..<8 { pixels[column] = UInt16(2048 + column) }
      }
    }
    let buffer = try decoder.copyIntoPixelBuffer(frame, width: 8, height: 4)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let samples = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: samples, count: 4)), [32768, 32784, 32800, 32816])
    XCTAssertEqual(CVPixelBufferGetWidthOfPlane(buffer, 1), 8)
    frame.pointee.width = 16
    for (component, stride) in zip([frame.pointee.data.0, frame.pointee.data.1, frame.pointee.data.2],
      [frame.pointee.linesize.0, frame.pointee.linesize.1, frame.pointee.linesize.2]) {
      let base = try XCTUnwrap(component)
      for row in 0..<4 {
        let pixels = UnsafeMutableRawPointer(base + row * Int(stride)).assumingMemoryBound(to: UInt16.self)
        for x in 8..<16 { pixels[x] = UInt16(2048 + x) }
      }
    }
    let resized = try decoder.copyIntoPixelBuffer(frame, width: 16, height: 4)
    XCTAssertEqual(CVPixelBufferGetWidth(resized), 16, "format-stable size changes must rebuild the pool")
  }
}
