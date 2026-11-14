import CoreMedia
import FFmpeg
import VideoToolbox
import XCTest
@testable import UmbelFFmpegSupport

/// Hardware for what it decodes — 4:2:0, at 8 bits and, except for H.264, at
/// 10 — and software for the rest, decided before the decoder opens.
final class HardwareDecodeSupportTests: XCTestCase {
  private func decides(
    _ codec: AVCodecID, _ format: AVPixelFormat, hardwareHasIt: Bool = true
  ) -> Bool {
    HardwareDecodeSupport.canDecode(codec: codec, format: format) { _ in hardwareHasIt }
  }

  func testEightBitFourTwoZeroGoesToTheHardware() {
    XCTAssertTrue(decides(AV_CODEC_ID_H264, AV_PIX_FMT_YUV420P))
    XCTAssertTrue(decides(AV_CODEC_ID_HEVC, AV_PIX_FMT_YUVJ420P))
  }

  func testTenBitGoesToTheHardwareExceptForH264() {
    XCTAssertTrue(decides(AV_CODEC_ID_HEVC, AV_PIX_FMT_YUV420P10LE))
    XCTAssertTrue(decides(AV_CODEC_ID_AV1, AV_PIX_FMT_YUV420P10LE))
    XCTAssertFalse(decides(AV_CODEC_ID_H264, AV_PIX_FMT_YUV420P10LE))
  }

  func testOtherChromaGoesToSoftware() {
    XCTAssertFalse(decides(AV_CODEC_ID_HEVC, AV_PIX_FMT_YUV422P10LE))
    XCTAssertFalse(decides(AV_CODEC_ID_H264, AV_PIX_FMT_YUV444P))
  }

  func testAnUndeclaredFormatTriesTheHardware() {
    XCTAssertTrue(decides(AV_CODEC_ID_H264, AV_PIX_FMT_NONE))
  }

  func testWhatThisHardwareLacksGoesToSoftware() {
    XCTAssertFalse(decides(AV_CODEC_ID_MPEG4, AV_PIX_FMT_YUV420P, hardwareHasIt: false))
  }

  func testCodecsWithoutAVideoToolboxPathGoToSoftware() {
    XCTAssertFalse(decides(AV_CODEC_ID_VP8, AV_PIX_FMT_YUV420P))
    XCTAssertFalse(decides(AV_CODEC_ID_PRORES, AV_PIX_FMT_YUV422P10LE))
  }

  func testTheHardwareIsAskedAboutTheCodec() {
    var asked: [CMVideoCodecType] = []
    _ = HardwareDecodeSupport.canDecode(codec: AV_CODEC_ID_AV1, format: AV_PIX_FMT_NONE) {
      asked.append($0)
      return true
    }
    XCTAssertEqual(asked, [kCMVideoCodecType_AV1])
  }
}
