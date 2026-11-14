import CoreMedia
import XCTest
@testable import UmbelCore
import UmbelFFmpegSupport

/// DV profile 5 packaged for the system: a dvh1 description it takes, and
/// the packets as samples it decodes itself.
final class DVSamplePackagerTests: XCTestCase {
  private struct Material {
    let hvcC: Data
    let record: FFmpegDOVIConfiguration
    let width: Int
    let height: Int
    let packets: [DemuxPacket]
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  /// A file's video setup and its first video packets, in decode order.
  private func material(_ name: String, packets count: Int = 30) async throws -> Material {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let found = await demux.codecParameters(for: video.id)
    let parameters = try XCTUnwrap(found)
    var packets: [DemuxPacket] = []
    while packets.count < count, let packet = try await demux.nextPacket() {
      if packet.trackID == video.id { packets.append(packet) }
    }
    let record = parameters.dovi ?? FFmpegDOVIConfiguration(
      versionMajor: 1, versionMinor: 0, profile: 5, level: 3, hasRPU: true,
      hasEnhancementLayer: false, hasBaseLayer: true, compatibility: 0, metadataCompression: 0)
    return Material(
      hvcC: parameters.extradata, record: record,
      width: parameters.width, height: parameters.height, packets: packets)
  }

  private func atoms(_ description: CMFormatDescription?) -> [String: Any] {
    guard let description else { return [:] }
    return CMFormatDescriptionGetExtension(
      description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
      as? [String: Any] ?? [:]
  }

  private func attachment(_ sample: CMSampleBuffer, _ key: CFString) -> Bool {
    guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
          CFArrayGetCount(array) > 0 else { return false }
    let first = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSDictionary.self)
    return (first[key] as? Bool) == true
  }

  /// hvcC with its arrays dropped: what a dvhe file with in-band parameter sets carries.
  private func bare(_ hvcC: Data) -> Data {
    var bare = hvcC.prefix(22)
    bare.append(0)
    return Data(bare)
  }

  private func package(
    _ packager: inout DVSamplePackager, _ packet: DemuxPacket, data: Data? = nil, hidden: Bool = false
  ) throws -> CMSampleBuffer? {
    try packager.sample(
      data: data ?? packet.data, presentationTime: packet.presentationTime,
      decodeTime: packet.decodeTime, isKeyframe: packet.isKeyframe, hidden: hidden)
  }

  func testAContainerHvcCWithParameterSetsIsUsedAsIs() async throws {
    let m = try await material("dv_p5.mp4")
    var packager = try DVSamplePackager(extradata: m.hvcC, record: m.record, width: m.width, height: m.height)
    let sample = try XCTUnwrap(try package(&packager, m.packets[0]))
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_DolbyVisionHEVC)
    XCTAssertEqual(atoms(description)["hvcC"] as? Data, m.hvcC)
    XCTAssertEqual(atoms(description)["dvcC"] as? Data, m.record.boxPayload)
  }

  func testParameterSetsComeFromTheFirstKeyframe() async throws {
    let m = try await material("dv_p5.mp4")
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: m.hvcC))
    // A dvhe file: nothing in its hvcC, the parameter sets in the keyframe.
    var packager = try DVSamplePackager(
      extradata: bare(m.hvcC), record: m.record, width: m.width, height: m.height)
    let inBand = HEVCParameterSets.lengthPrefixed([sets.vps, sets.sps, sets.pps]) + m.packets[0].data
    let sample = try XCTUnwrap(try package(&packager, m.packets[0], data: inBand))

    var expected: CMFormatDescription?
    let joined = sets.vps + sets.sps + sets.pps
    joined.withUnsafeBytes { raw in
      let base = raw.bindMemory(to: UInt8.self).baseAddress!
      let pointers = [base, base + sets.vps.count, base + sets.vps.count + sets.sps.count]
      _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers,
        parameterSetSizes: [sets.vps.count, sets.sps.count, sets.pps.count],
        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &expected)
    }
    let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kCMVideoCodecType_DolbyVisionHEVC)
    XCTAssertEqual(atoms(description)["hvcC"] as? Data, atoms(expected)["hvcC"] as? Data)
    XCTAssertNotNil(atoms(description)["hvcC"] as? Data)
    XCTAssertEqual(atoms(description)["dvcC"] as? Data, m.record.boxPayload)
  }

  func testPacketsBeforeTheFirstKeyframeAreDropped() async throws {
    let m = try await material("dv_p5.mp4")
    var packager = try DVSamplePackager(extradata: m.hvcC, record: m.record, width: m.width, height: m.height)
    let later = m.packets.filter { !$0.isKeyframe }.prefix(2)
    XCTAssertEqual(later.count, 2)
    for packet in later { XCTAssertNil(try package(&packager, packet)) }
    XCTAssertNotNil(try package(&packager, m.packets[0]), "from a keyframe on, there are samples")
    XCTAssertNotNil(try package(&packager, later.first!))
  }

  func testNonKeyframesAreNotSyncAndHiddenOnesAreNotShown() async throws {
    let m = try await material("dv_p5.mp4")
    var packager = try DVSamplePackager(extradata: m.hvcC, record: m.record, width: m.width, height: m.height)
    let key = try XCTUnwrap(try package(&packager, m.packets[0]))
    XCTAssertFalse(attachment(key, kCMSampleAttachmentKey_NotSync))
    XCTAssertFalse(attachment(key, kCMSampleAttachmentKey_DoNotDisplay))
    let other = try XCTUnwrap(m.packets.first { !$0.isKeyframe })
    let hidden = try XCTUnwrap(try package(&packager, other, hidden: true))
    XCTAssertTrue(attachment(hidden, kCMSampleAttachmentKey_NotSync))
    XCTAssertTrue(attachment(hidden, kCMSampleAttachmentKey_DoNotDisplay))
  }

  func testTimesAndSizesAreThePackets() async throws {
    let m = try await material("dv_p5.mp4")
    var packager = try DVSamplePackager(extradata: m.hvcC, record: m.record, width: m.width, height: m.height)
    for packet in m.packets.prefix(5) {
      let sample = try XCTUnwrap(try package(&packager, packet))
      XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), packet.presentationTime)
      XCTAssertEqual(CMSampleBufferGetDecodeTimeStamp(sample), packet.decodeTime)
      XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), packet.data.count)
    }
  }

  func testChangedParameterSetsMakeANewDescription() async throws {
    let m = try await material("dv_p5.mp4")
    let other = try await material("hdr10_pq.mp4", packets: 1)
    let otherSets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: other.hvcC))
    var packager = try DVSamplePackager(extradata: m.hvcC, record: m.record, width: m.width, height: m.height)
    let first = try XCTUnwrap(try package(&packager, m.packets[0]))
    let keyframes = m.packets.filter(\.isKeyframe)
    XCTAssertGreaterThanOrEqual(keyframes.count, 2)
    // An inserted run encoded otherwise: its keyframe carries other parameter sets.
    let changed = HEVCParameterSets.lengthPrefixed([otherSets.vps, otherSets.sps, otherSets.pps])
      + keyframes[1].data
    let second = try XCTUnwrap(try package(&packager, keyframes[1], data: changed))
    let before = try XCTUnwrap(CMSampleBufferGetFormatDescription(first))
    let after = try XCTUnwrap(CMSampleBufferGetFormatDescription(second))
    XCTAssertNotEqual(atoms(before)["hvcC"] as? Data, atoms(after)["hvcC"] as? Data)
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(after), kCMVideoCodecType_DolbyVisionHEVC)
  }

  /// Real files carry the parameter sets for a keyframe at the tail of the
  /// sample before it: taken from there, they serve the keyframe after.
  func testParameterSetsBeforeTheKeyframeServeIt() async throws {
    let m = try await material("dv_p5.mp4")
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: m.hvcC))
    var packager = try DVSamplePackager(
      extradata: bare(m.hvcC), record: m.record, width: m.width, height: m.height)
    let keyframes = m.packets.filter(\.isKeyframe)
    let before = try XCTUnwrap(m.packets.last { !$0.isKeyframe && $0.decodeTime < keyframes[1].decodeTime })
    let carrying = before.data + HEVCParameterSets.lengthPrefixed([sets.vps, sets.sps, sets.pps])
    XCTAssertNil(try package(&packager, before, data: carrying), "not a keyframe: nothing to decode it against")
    XCTAssertNotNil(try package(&packager, keyframes[1]), "the keyframe after has what it needs")
  }

  /// A seek lands on a keyframe that need not carry them: those seen before
  /// still hold.
  func testParameterSetsSurviveAReset() async throws {
    let m = try await material("dv_p5.mp4")
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: m.hvcC))
    var packager = try DVSamplePackager(
      extradata: bare(m.hvcC), record: m.record, width: m.width, height: m.height)
    let inBand = HEVCParameterSets.lengthPrefixed([sets.vps, sets.sps, sets.pps]) + m.packets[0].data
    XCTAssertNotNil(try package(&packager, m.packets[0], data: inBand))
    packager.reset()
    let keyframes = m.packets.filter(\.isKeyframe)
    XCTAssertNotNil(try package(&packager, keyframes[1]), "a keyframe without them, after a seek")
  }

  /// Taken from the start of the stream when it opened: a seek before the
  /// first packet is played has them all the same.
  func testPrimedParameterSetsServeAKeyframeWithoutThem() async throws {
    let m = try await material("dv_p5.mp4")
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: m.hvcC))
    var packager = try DVSamplePackager(
      extradata: bare(m.hvcC), record: m.record, width: m.width, height: m.height, primed: sets)
    let keyframes = m.packets.filter(\.isKeyframe)
    XCTAssertNotNil(try package(&packager, keyframes[1]))
  }

  /// A stream whose parameter sets are nowhere — not in its hvcC, not at
  /// its start, not in its packets — fails with the reason once keyframes
  /// keep coming without them. It played as "ended" at 0 before, having
  /// shown nothing. Parameter sets that come late are waited for: a real
  /// file puts them at the tail of the sample before a keyframe.
  func testKeyframesWithoutParameterSetsAnywhereFail() async throws {
    let m = try await material("dv_p5.mp4", packets: 50)
    var packager = try DVSamplePackager(
      extradata: bare(m.hvcC), record: m.record, width: m.width, height: m.height)
    let keyframes = m.packets.filter(\.isKeyframe)
    XCTAssertGreaterThanOrEqual(keyframes.count, 3)
    XCTAssertNil(try package(&packager, keyframes[0]))
    XCTAssertNil(try package(&packager, keyframes[1]), "still waited for")
    do {
      _ = try package(&packager, keyframes[2])
      XCTFail("the third keyframe without parameter sets went by")
    } catch UmbelError.unsupportedCodec(let what) {
      XCTAssertTrue(what.contains("parameter sets"), what)
    }
  }

  func testResetWaitsForAKeyframeAgain() async throws {
    let m = try await material("dv_p5.mp4")
    var packager = try DVSamplePackager(extradata: m.hvcC, record: m.record, width: m.width, height: m.height)
    XCTAssertNotNil(try package(&packager, m.packets[0]))
    packager.reset()
    let other = try XCTUnwrap(m.packets.first { !$0.isKeyframe })
    XCTAssertNil(try package(&packager, other))
  }
}
