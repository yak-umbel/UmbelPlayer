import CoreVideo
import FFmpeg
import VideoToolbox
import XCTest
@testable import UmbelFFmpegSupport

private actor AV1Bytes {
  let data: Data
  var offset = 0
  init(_ data: Data) { self.data = data }
  func read(_ count: Int) -> Data {
    let end = min(offset + count, data.count)
    defer { offset = end }
    return data.subdata(in: offset..<end)
  }
  func seek(_ to: Int64) { offset = min(Int(to), data.count) }
}

final class AV1DecoderTests: XCTestCase {
  private func decode(depth: Int, preferHardware: Bool) async throws {
    try XCTSkipIf(
      preferHardware && HostEnvironment.isVirtualMachine,
      "a virtual machine reports AV1 hardware decoding it cannot do")
    let data = try Data(contentsOf: FixtureLocator.url(for: "av1_\(depth)bit.mp4"))
    let reader = AV1Bytes(data)
    let demux = FFmpegDemuxer(callbacks: FFmpegIOCallbacks(
      read: { await reader.read($0) }, seek: { await reader.seek($0) },
      totalLength: { Int64(data.count) }, canSeek: true), configuration: .init())
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.streams()
    let video = try XCTUnwrap(tracks.first { $0.mediaType == .video })
    let decoder = try await demux.makeVideoDecoder(
      streamIndex: video.index, preferHardware: preferHardware)
    defer { decoder.close() }
    #if os(macOS)
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
    #endif
    let hardware = preferHardware && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    XCTAssertEqual(decoder.isHardwareAccelerated, hardware)
    var times: [Int] = []
    func collect(_ frames: [FFmpegVideoFrame]) throws {
      for frame in frames {
        XCTAssertEqual(frame.wasHardwareDecoded, hardware)
        let number = Int((Double(frame.pts) * Double(frame.timeBaseNum) / Double(frame.timeBaseDen) * 30).rounded())
        times.append(number)
        let buffer = frame.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 240)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), depth == 8
          ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        // Check actual decoded pixels as well as frame count and timestamps.
        if number % 30 == 1 || number % 30 == 15 {
          CVPixelBufferLockBaseAddress(buffer, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
          let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
          let luma = depth == 8 ? Int(base.load(as: UInt8.self)) : Int(base.load(as: UInt16.self)) >> 8
          XCTAssertEqual(luma, number % 30 == 1 ? 235 : 16, accuracy: 8)
        }
      }
    }
    while let packet = try await demux.readPacket() {
      if packet.streamIndex == video.index { try collect(decoder.decode(packet)) }
    }
    try collect(decoder.decode(FFmpegPacket(
      streamIndex: video.index, data: Data(), pts: FFmpegPacket.noTimestamp,
      dts: FFmpegPacket.noTimestamp, duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false)))
    XCTAssertEqual(times, Array(0..<180), "all frames, in presentation order, including decoder drain")
    XCTAssertEqual(decoder.damagedFrameCount, 0)
  }

  func testEightBitSoftwareDecodesEveryPicture() async throws {
    try await decode(depth: 8, preferHardware: false)
  }

  func testTenBitSoftwareKeepsPrecisionAndEveryPicture() async throws {
    try await decode(depth: 10, preferHardware: false)
  }

  func testAutomaticEightBitUsesHardwareWhenAvailable() async throws {
    try await decode(depth: 8, preferHardware: true)
  }

  func testAutomaticTenBitUsesHardwareWhenAvailable() async throws {
    try await decode(depth: 10, preferHardware: true)
  }
}
