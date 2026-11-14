import CoreMedia
import CoreVideo
import FFmpeg
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

final class SystemPixelDecodeConfigurationTests: XCTestCase {
  func testP5AcceptsFullRangeSystemPixelsWithoutInventingACompatibleBaseLayer() throws {
    let source = try parameters(compatibility: 0, profile: 5, range: AVCOL_RANGE_JPEG)
    let configuration = try SystemPixelDecodeConfiguration(record: XCTUnwrap(source.dovi),
      pixels: source.videoFormat.map(VideoPixelDescription.init(ffmpeg:)))
    XCTAssertEqual(configuration.outputPixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    try configuration.validate(parameters: source)
    try configuration.validate(description: description(hvcC: hvcC(), extensions: [
      kCMFormatDescriptionExtension_FullRangeVideo as String: true,
      kCMFormatDescriptionExtension_BitsPerComponent as String: 10,
    ]))
    XCTAssertThrowsError(try configuration.validate(description: description(hvcC: hvcC(), extensions: [
      kCMFormatDescriptionExtension_FullRangeVideo as String: false,
    ])))
    XCTAssertThrowsError(try configuration.validate(parameters:
      parameters(compatibility: 0, profile: 5, range: AVCOL_RANGE_MPEG)))
  }

  func testMissingSystemParameterSetsTriggersCompatibleRecovery() async throws {
    let source = try parameters(compatibility: 1)
    let session = try SystemPixelDecodeSession(parameters: source, record: XCTUnwrap(source.dovi))
    let keyframe = packet(parameters: source, isKeyframe: true)
    for _ in 0..<2 {
      let frames = try await session.decode(keyframe, hidden: false)
      XCTAssertTrue(frames.isEmpty)
    }
    do {
      _ = try await session.decode(keyframe, hidden: false)
      XCTFail("system packaging refusal must permit the compatible decoder to recover")
    } catch {
      guard case UmbelError.videoRenderUnavailable = error else { return XCTFail("unexpected error: \(error)") }
    }
    await session.close()
  }

  func testCompressedRecoveryKeepsInBandHeadersSeenBeforeTheRetainedKeyframe() async throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/dv_p5.mp4")
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let found = await demux.codecParameters(for: video.id)
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: XCTUnwrap(found).extradata))
    let source = try parameters(compatibility: 0, profile: 5, range: AVCOL_RANGE_JPEG)
    let record = try XCTUnwrap(source.dovi)
    let session = try SystemPixelDecodeSession(parameters: source, record: record)
    let headers = [sets.vps, sets.sps, sets.pps].reduce(into: Data()) {
      $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1)
    }
    // Only prime the packager: a non-key packet before random access cannot
    // start a native decoder. The retained GOP need not repeat these headers.
    let preceding = DemuxPacket(trackID: video.id, data: headers,
      presentationTime: .zero, decodeTime: .zero, duration: .invalid, isKeyframe: false)
    let primed = try await session.decode(preceding, hidden: true)
    XCTAssertTrue(primed.isEmpty)
    await session.close()
    let recovery = await session.compressedRecovery()
    let keyframe = DemuxPacket(trackID: video.id, data: Data([0, 0, 0, 1, 0x26, 1, 0x80]),
      presentationTime: .zero, decodeTime: .zero, duration: .invalid, isKeyframe: true)
    // This test inspects packaging state, not decoding synthetic picture data.
    let frames = try await recovery.decode(keyframe, hidden: false)
    let sample = try XCTUnwrap(frames.first?.compressedSample)
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(description,
      extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any])
    let recovered = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: XCTUnwrap(atoms["hvcC"] as? Data)))
    XCTAssertEqual(recovered.vps, sets.vps)
    XCTAssertEqual(recovered.sps, sets.sps)
    XCTAssertEqual(recovered.pps, sets.pps)
    let rebuilt = try SystemDecodeSession(parameters: source, record: record)
    let lostHeaders = try await rebuilt.decode(keyframe, hidden: false)
    XCTAssertTrue(lostHeaders.isEmpty, "rebuilding from the initial description loses the in-band headers")
  }

  func testActualFormatRejectsUnknownPrecisionAndChromaInsteadOfAssumingTheInitialFormat() throws {
    let source = try parameters(compatibility: 1)
    let configuration = try SystemPixelDecodeConfiguration(record: XCTUnwrap(source.dovi),
      pixels: .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
    let invalid: [Data?] = [nil, Data(), Data(hvcC().prefix(18)), hvcC(version: 2),
                           hvcC(chroma: 0), hvcC(chroma: 2), hvcC(chroma: 3),
                           hvcC(lumaDepth: 8), hvcC(lumaDepth: 12), hvcC(chromaDepth: 8), hvcC(chromaDepth: 12)]
    for bytes in invalid {
      XCTAssertThrowsError(try configuration.validate(description: description(hvcC: bytes))) {
        guard case UmbelError.videoRenderUnavailable = $0 else { return XCTFail("unexpected error: \($0)") }
      }
    }
  }

  func testActualFormatRejectsExplicitColorConflicts() throws {
    let source = try parameters(compatibility: 1)
    let configuration = try SystemPixelDecodeConfiguration(record: XCTUnwrap(source.dovi),
      pixels: .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
    let conflicts: [(CFString, Any)] = [
      (kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
      (kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG),
      (kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2),
      (kCMFormatDescriptionExtension_FullRangeVideo, true),
      (kCMFormatDescriptionExtension_BitsPerComponent, 12),
    ]
    for (key, value) in conflicts {
      XCTAssertThrowsError(try configuration.validate(description: description(hvcC: hvcC(),
        extensions: [key as String: value]))) {
        guard case UmbelError.videoRenderUnavailable = $0 else { return XCTFail("unexpected error: \($0)") }
      }
    }
  }

  func testActualFormatAcceptsTenBit420AndItsDeclaredBaseLayerColor() throws {
    for compatibility in [UInt8(1), 4] {
      let source = try parameters(compatibility: compatibility)
      let configuration = try SystemPixelDecodeConfiguration(record: XCTUnwrap(source.dovi),
        pixels: .init(cvFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
      try configuration.validate(description: description(hvcC: hvcC()))
      try configuration.validate(description: description(hvcC: hvcC(), extensions: [
        kCMFormatDescriptionExtension_ColorPrimaries as String: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
        kCMFormatDescriptionExtension_TransferFunction as String: compatibility == 1
          ? kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ : kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
        kCMFormatDescriptionExtension_YCbCrMatrix as String: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
        kCMFormatDescriptionExtension_FullRangeVideo as String: false,
        kCMFormatDescriptionExtension_BitsPerComponent as String: 10,
      ]))
    }
  }

  func testContainerAndInBandFixtureDescriptionsRetainTheirQualifiedFormat() async throws {
    for name in ["dv_p81.mp4", "dv_p84.mp4"] {
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
      let demux = DemuxSession(source: try UmbelFileSource(url: url))
      try await demux.open()
      addTeardownBlock { await demux.close() }
      let tracks = await demux.tracks
      let video = try XCTUnwrap(tracks.first { $0.kind == .video })
      let found = await demux.codecParameters(for: video.id)
      let source = try XCTUnwrap(found)
      let record = try XCTUnwrap(source.dovi)
      let configuration = try SystemPixelDecodeConfiguration(record: record,
        pixels: source.videoFormat.map(VideoPixelDescription.init(ffmpeg:)))
      let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: source.extradata))
      let container = try DVSamplePackager(extradata: source.extradata, record: record,
        width: source.width, height: source.height)
      try configuration.validate(description: XCTUnwrap(container.description))
      var inBand = try DVSamplePackager(extradata: Data(), record: record,
        width: source.width, height: source.height)
      let annexB = [sets.vps, sets.sps, sets.pps].reduce(into: Data()) {
        $0.append(contentsOf: [0, 0, 0, 1]); $0.append($1)
      }
      _ = try inBand.sample(data: annexB, presentationTime: .zero, decodeTime: .zero,
        isKeyframe: true, hidden: false)
      try configuration.validate(description: XCTUnwrap(inBand.description))
    }
  }

  func testExplicitSourceColorConflictsRequireFallback() async throws {
    for replacement in [
      try parameters(compatibility: 1, transfer: AVCOL_TRC_BT709),
      try parameters(compatibility: 1, primaries: AVCOL_PRI_BT709),
      try parameters(compatibility: 1, matrix: AVCOL_SPC_BT709),
      try parameters(compatibility: 1, range: AVCOL_RANGE_JPEG),
    ] {
      XCTAssertThrowsError(try SystemPixelDecodeSession(
        parameters: replacement, record: XCTUnwrap(replacement.dovi))) {
        guard case UmbelError.videoRenderUnavailable = $0 else { return XCTFail("unexpected error: \($0)") }
      }
      try await assertConfigurationRejected(initial: parameters(compatibility: 1), replacement: replacement)
    }
  }

  func testP81AcceptsReplacementParametersWithinItsOriginalConfiguration() async throws {
    let original = try parameters(compatibility: 1)
    let session = try SystemPixelDecodeSession(parameters: original, record: XCTUnwrap(original.dovi))
    let replacement = try parameters(compatibility: 1, width: 640, height: 360)
    let frames = try await session.decode(packet(parameters: replacement), hidden: false)
    XCTAssertTrue(frames.isEmpty, "a legal change still waits for a random access picture")
    await session.close()
  }

  func testP84AcceptsReplacementParametersWithinItsOriginalConfiguration() async throws {
    let original = try parameters(compatibility: 4)
    let session = try SystemPixelDecodeSession(parameters: original, record: XCTUnwrap(original.dovi))
    let frames = try await session.decode(packet(parameters: parameters(compatibility: 4)), hidden: false)
    XCTAssertTrue(frames.isEmpty)
    await session.close()
  }

  func testP81CannotBorrowP84QualificationAfterAParameterChange() async throws {
    try await assertConfigurationRejected(initial: parameters(compatibility: 1),
      replacement: parameters(compatibility: 4))
  }

  func testP84CannotBorrowP81QualificationAfterAParameterChange() async throws {
    try await assertConfigurationRejected(initial: parameters(compatibility: 4),
      replacement: parameters(compatibility: 1))
  }

  func testChangedPixelPrecisionAndSamplingRequireFallback() async throws {
    for pixelFormat in [AV_PIX_FMT_NONE, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV420P12LE,
                        AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_GBRP10LE] {
      try await assertConfigurationRejected(initial: parameters(compatibility: 4),
        replacement: parameters(compatibility: 4, pixelFormat: pixelFormat))
    }
  }

  func testUnverifiedInitialPixelFormatIsNotForcedToTenBit420() throws {
    for pixelFormat in [AV_PIX_FMT_NONE, AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV420P12LE,
                        AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_GBRP10LE] {
      let source = try parameters(compatibility: 1, pixelFormat: pixelFormat)
      XCTAssertThrowsError(try SystemPixelDecodeSession(parameters: source, record: XCTUnwrap(source.dovi))) {
        guard case UmbelError.videoRenderUnavailable = $0 else { return XCTFail("unexpected error: \($0)") }
      }
    }
  }

  func testMetadataFormatChangeRequiresFallback() async throws {
    for replacement in [
      try parameters(compatibility: 4, versionMajor: 2),
      try parameters(compatibility: 4, versionMinor: 1),
      try parameters(compatibility: 4, level: 6),
      try parameters(compatibility: 4, metadataCompression: 1),
      try parameters(compatibility: 4, hasRPU: false),
      try parameters(compatibility: 4, hasEnhancementLayer: true),
    ] {
      try await assertConfigurationRejected(initial: parameters(compatibility: 4), replacement: replacement)
    }
  }

  func testMissingCompatibleBaseLayerCannotStartOrRecoverThroughBaseLayerDecoding() async throws {
    for replacement in [
      try parameters(compatibility: 4, hasBaseLayer: false),
      try parameters(compatibility: 0),
      try parameters(compatibility: 9),
    ] {
      XCTAssertThrowsError(try SystemPixelDecodeSession(
        parameters: replacement, record: XCTUnwrap(replacement.dovi))) {
        guard case UmbelError.unsupportedDynamicHDR = $0 else { return XCTFail("unexpected error: \($0)") }
      }
      let original = try parameters(compatibility: 4)
      let session = try SystemPixelDecodeSession(parameters: original, record: XCTUnwrap(original.dovi))
      do {
        _ = try await session.decode(packet(parameters: replacement), hidden: false)
        XCTFail("no compatible base layer is available for recovery")
      } catch {
        guard case UmbelError.unsupportedDynamicHDR = error else { return XCTFail("unexpected error: \(error)") }
      }
      await session.close()
    }
  }

  func testFlushDoesNotExpandTheInitialConfigurationQualification() async throws {
    let original = try parameters(compatibility: 1)
    let session = try SystemPixelDecodeSession(parameters: original, record: XCTUnwrap(original.dovi))
    await session.flush()
    do {
      _ = try await session.decode(packet(parameters: parameters(compatibility: 4)), hidden: false)
      XCTFail("seek must not authorize a different compatibility class")
    } catch {
      guard case UmbelError.videoRenderUnavailable = error else { return XCTFail("unexpected error: \(error)") }
    }
    await session.close()
  }

  func testStoppedSessionIgnoresAChangedConfiguration() async throws {
    let original = try parameters(compatibility: 1)
    let session = try SystemPixelDecodeSession(parameters: original, record: XCTUnwrap(original.dovi))
    await session.close()
    let frames = try await session.decode(packet(parameters: parameters(compatibility: 4)), hidden: false)
    XCTAssertTrue(frames.isEmpty)
  }

  private func assertConfigurationRejected(
    initial: FFmpegCodecParameters, replacement: FFmpegCodecParameters,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let session = try SystemPixelDecodeSession(parameters: initial, record: XCTUnwrap(initial.dovi))
    do {
      _ = try await session.decode(packet(parameters: replacement), hidden: false)
      XCTFail("changed configuration must select a compatible fallback", file: file, line: line)
    } catch {
      guard case UmbelError.videoRenderUnavailable = error else {
        return XCTFail("unexpected error: \(error)", file: file, line: line)
      }
    }
    await session.close()
  }

  private func packet(parameters: FFmpegCodecParameters, isKeyframe: Bool = false) -> DemuxPacket {
    // An empty payload exercises configuration and missing-header behavior
    // through the real packager without requiring a device decoder.
    var packet = DemuxPacket(trackID: .init(rawValue: 0), data: Data(),
      presentationTime: .zero, decodeTime: .zero, duration: .invalid, isKeyframe: isKeyframe)
    packet.decoderParameters = parameters
    return packet
  }

  private func parameters(
    compatibility: UInt8, profile: UInt8 = 8, pixelFormat: AVPixelFormat = AV_PIX_FMT_YUV420P10LE,
    versionMajor: UInt8 = 1, versionMinor: UInt8 = 0, level: UInt8 = 3,
    metadataCompression: UInt8 = 0, hasRPU: Bool = true,
    hasEnhancementLayer: Bool = false, hasBaseLayer: Bool = true,
    width: Int32 = 320, height: Int32 = 240,
    transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
    primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
    matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED,
    range: AVColorRange = AVCOL_RANGE_UNSPECIFIED
  ) throws -> FFmpegCodecParameters {
    var allocated = avcodec_parameters_alloc()
    let raw = try XCTUnwrap(allocated)
    defer { avcodec_parameters_free(&allocated) }
    raw.pointee.codec_type = AVMEDIA_TYPE_VIDEO
    raw.pointee.codec_id = AV_CODEC_ID_HEVC
    raw.pointee.format = pixelFormat.rawValue
    raw.pointee.width = width
    raw.pointee.height = height
    raw.pointee.color_trc = transfer
    raw.pointee.color_primaries = primaries
    raw.pointee.color_space = matrix
    raw.pointee.color_range = range
    let side = try XCTUnwrap(av_packet_side_data_new(&raw.pointee.coded_side_data,
      &raw.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF,
      MemoryLayout<AVDOVIDecoderConfigurationRecord>.size, 0))
    var record = AVDOVIDecoderConfigurationRecord()
    record.dv_version_major = versionMajor
    record.dv_version_minor = versionMinor
    record.dv_profile = profile
    record.dv_level = level
    record.dv_bl_signal_compatibility_id = compatibility
    record.dv_md_compression = metadataCompression
    record.rpu_present_flag = hasRPU ? 1 : 0
    record.el_present_flag = hasEnhancementLayer ? 1 : 0
    record.bl_present_flag = hasBaseLayer ? 1 : 0
    UnsafeMutableRawPointer(try XCTUnwrap(side.pointee.data))
      .storeBytes(of: record, as: AVDOVIDecoderConfigurationRecord.self)
    return try XCTUnwrap(FFmpegCodecParameters(copying: raw, timeBaseNum: 1, timeBaseDen: 25,
      sampleAspect: AVRational(num: 1, den: 1)))
  }

  private func description(hvcC: Data?, extensions: [String: Any] = [:]) throws -> CMVideoFormatDescription {
    var extensions = extensions
    if let hvcC {
      extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = ["hvcC": hvcC]
    }
    var result: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_DolbyVisionHEVC,
      width: 320, height: 240, extensions: extensions as CFDictionary, formatDescriptionOut: &result)
    XCTAssertEqual(status, noErr)
    return try XCTUnwrap(result)
  }

  private func hvcC(version: UInt8 = 1, chroma: UInt8 = 1, lumaDepth: UInt8 = 10, chromaDepth: UInt8 = 10) -> Data {
    // HEVCDecoderConfigurationRecord: chromaFormat and bitDepth*Minus8.
    var bytes = [UInt8](repeating: 0, count: 23)
    bytes[0] = version
    bytes[16] = 0xFC | chroma
    bytes[17] = 0xF8 | (lumaDepth - 8)
    bytes[18] = 0xF8 | (chromaDepth - 8)
    return Data(bytes)
  }
}
