import XCTest
import FFmpeg
@testable import UmbelFFmpegSupport

/// A fixture's bytes, read in order.
private actor FixtureBytes {
  private let data: Data
  private var position = 0

  init(named name: String) throws {
    data = try Data(contentsOf: FixtureLocator.url(for: name))
  }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }

  var length: Int64 { Int64(data.count) }
}

private func openedDemuxer(named name: String) async throws -> FFmpegDemuxer {
  let bytes = try FixtureBytes(named: name)
  let demuxer = FFmpegDemuxer(
    callbacks: FFmpegIOCallbacks(
      read: { maxLength in await bytes.read(maxLength: maxLength) },
      seek: { offset in await bytes.seek(to: offset) },
      totalLength: { await bytes.length },
      canSeek: true),
    configuration: .init())
  try await demuxer.open()
  return demuxer
}

final class FFmpegDOVIConfigurationTests: XCTestCase {
  func testParameterEqualityIncludesDynamicConfiguration() throws {
    func parameters(_ compatibility: UInt8) throws -> FFmpegCodecParameters {
      var allocated = avcodec_parameters_alloc()
      let raw = try XCTUnwrap(allocated)
      defer { avcodec_parameters_free(&allocated) }
      raw.pointee.codec_type = AVMEDIA_TYPE_VIDEO
      raw.pointee.codec_id = AV_CODEC_ID_HEVC
      let side = try XCTUnwrap(av_packet_side_data_new(&raw.pointee.coded_side_data,
        &raw.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF,
        MemoryLayout<AVDOVIDecoderConfigurationRecord>.size, 0))
      let bytes = try XCTUnwrap(side.pointee.data)
      var record = AVDOVIDecoderConfigurationRecord()
      record.dv_profile = 8
      record.dv_level = 3
      record.bl_present_flag = 1
      record.rpu_present_flag = 1
      record.dv_bl_signal_compatibility_id = compatibility
      UnsafeMutableRawPointer(bytes).storeBytes(of: record, as: AVDOVIDecoderConfigurationRecord.self)
      return try XCTUnwrap(FFmpegCodecParameters(copying: raw, timeBaseNum: 1, timeBaseDen: 25,
        sampleAspect: AVRational(num: 1, den: 1)))
    }
    XCTAssertFalse(try parameters(1).isSameFormat(as: parameters(4)),
      "unchanged HEVC setup bytes do not make different dynamic configurations interchangeable")
  }
  private func record(profile: Int, compatibility: Int) -> FFmpegDOVIConfiguration {
    FFmpegDOVIConfiguration(
      versionMajor: 1, versionMinor: 0, profile: profile, level: 3,
      hasRPU: true, hasEnhancementLayer: false, hasBaseLayer: true,
      compatibility: compatibility, metadataCompression: 0)
  }

  private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

  /// The very bytes a real profile 5 file carries in its sample entry.
  func testThePayloadIsTheBoxAsFilesCarryIt() {
    let p5 = record(profile: 5, compatibility: 0)
    XCTAssertEqual(p5.boxType, "dvcC")
    XCTAssertEqual(hex(p5.boxPayload), "01000a1d" + String(repeating: "00", count: 20))
  }

  func testProfileEightIsDvvC() {
    let p84 = record(profile: 8, compatibility: 4)
    XCTAssertEqual(p84.boxType, "dvvC")
    XCTAssertEqual(p84.boxPayload.count, 24)
    XCTAssertEqual(p84.boxPayload[4], UInt8(4 << 4), "the base layer's compatibility sits in the fifth byte's high bits")
  }

  func testTheFixturesRecordsAreRead() async throws {
    let p5 = try await openedDemuxer(named: "dv_p5.mp4")
    addTeardownBlock { await p5.close() }
    let p5Streams = await p5.streams()
    let p5Video = try XCTUnwrap(p5Streams.first { $0.mediaType == .video })
    XCTAssertEqual(p5Video.dovi?.profile, 5)
    XCTAssertEqual(p5Video.dovi?.compatibility, 0)
    XCTAssertEqual(p5Video.dovi?.hasBaseLayer, true)

    let p84 = try await openedDemuxer(named: "dv_p84.mp4")
    addTeardownBlock { await p84.close() }
    let p84Streams = await p84.streams()
    let p84Video = try XCTUnwrap(p84Streams.first { $0.mediaType == .video })
    XCTAssertEqual(p84Video.dovi?.profile, 8)
    XCTAssertEqual(p84Video.dovi?.compatibility, 4)
  }

  func testAStreamWithoutOneHasNone() async throws {
    let plain = try await openedDemuxer(named: "hdr10_pq.mp4")
    addTeardownBlock { await plain.close() }
    let streams = await plain.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    XCTAssertNil(video.dovi)
  }

  func testCodecParametersCarryTheRecordAndSetup() async throws {
    let demuxer = try await openedDemuxer(named: "dv_p5.mp4")
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let found = await demuxer.codecParameters(streamIndex: video.index)
    let parameters = try XCTUnwrap(found)
    XCTAssertEqual(parameters.dovi?.profile, 5)
    XCTAssertEqual(parameters.extradata.first, 0x01, "an hvcC record starts with its version, 1")
    XCTAssertEqual(parameters.width, 320)
    XCTAssertEqual(parameters.height, 240)
  }
}
