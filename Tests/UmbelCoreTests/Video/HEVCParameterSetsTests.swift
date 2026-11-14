import XCTest
@testable import UmbelCore

/// HEVC's NAL units, as samples and hvcC records carry them.
final class HEVCParameterSetsTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  func testLengthPrefixedUnitsAreSplit() {
    let data = Data([0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 3, 0x42, 0x01, 0x02])
    XCTAssertEqual(
      HEVCParameterSets.units(in: data, lengthSize: 4),
      [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02])])
  }

  func testShorterLengthsAreRead() {
    let data = Data([0, 2, 0x40, 0x01, 0, 1, 0x26])
    XCTAssertEqual(HEVCParameterSets.units(in: data, lengthSize: 2), [Data([0x40, 0x01]), Data([0x26])])
  }

  func testAnnexBIsSplitOnBothStartCodes() {
    let data = Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 1, 0x42, 0x01, 0x02, 0, 0, 1, 0x44, 0x01])
    XCTAssertEqual(
      HEVCParameterSets.units(in: data, lengthSize: nil),
      [Data([0x40, 0x01]), Data([0x42, 0x01, 0x02]), Data([0x44, 0x01])])
  }

  func testAFrameCutShortKeepsWhatIsWhole() {
    // The second unit claims 9 bytes and has 2: it is dropped, not read past.
    let data = Data([0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 9, 0x42, 0x01])
    XCTAssertEqual(HEVCParameterSets.units(in: data, lengthSize: 4), [Data([0x40, 0x01])])
  }

  func testUnitsAreWrittenBehindFourByteLengths() {
    let written = HEVCParameterSets.lengthPrefixed([Data([0x40, 0x01]), Data([0x26])])
    XCTAssertEqual(written, Data([0, 0, 0, 2, 0x40, 0x01, 0, 0, 0, 1, 0x26]))
  }

  func testParameterSetsAreFoundByType() {
    // Types sit in bits 1–6 of the first byte: 32 VPS (0x40), 33 SPS (0x42), 34 PPS (0x44).
    let pps = Data([0x44, 0x01, 0xAA]), vps = Data([0x40, 0x01, 0xBB]), sps = Data([0x42, 0x01, 0xCC])
    let slice = Data([0x26, 0x01, 0xDD])
    let found = HEVCParameterSets.parameterSets(in: [pps, slice, vps, sps])
    XCTAssertEqual(found?.vps, vps)
    XCTAssertEqual(found?.sps, sps)
    XCTAssertEqual(found?.pps, pps)
    XCTAssertNil(HEVCParameterSets.parameterSets(in: [vps, sps, slice]), "all three or none")
  }

  func testTheFixturesHvcCIsReadWithItsArrays() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("dv_p5.mp4")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let found = await demux.codecParameters(for: video.id)
    let hvcC = try XCTUnwrap(found).extradata
    XCTAssertTrue(HEVCParameterSets.hvcCHasArrays(hvcC))
    XCTAssertEqual(HEVCParameterSets.lengthSize(ofHvcC: hvcC), 4)
    let sets = try XCTUnwrap(HEVCParameterSets.arrays(inHvcC: hvcC))
    XCTAssertEqual((sets.vps.first! >> 1) & 0x3F, 32)
    XCTAssertEqual((sets.sps.first! >> 1) & 0x3F, 33)
    XCTAssertEqual((sets.pps.first! >> 1) & 0x3F, 34)
  }

  func testAnHvcCWithoutArraysIsTold() {
    var bare = Data(repeating: 0, count: 23)
    bare[0] = 1
    bare[21] = 0x0F  // length size 4
    XCTAssertFalse(HEVCParameterSets.hvcCHasArrays(bare))
    XCTAssertNil(HEVCParameterSets.arrays(inHvcC: bare))
    XCTAssertFalse(HEVCParameterSets.hvcCHasArrays(Data([1, 2, 3])), "too short to be one")
  }
}
