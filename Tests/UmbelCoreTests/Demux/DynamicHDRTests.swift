import XCTest
@testable import UmbelCore

/// DV tracks: told apart, labelled neutrally, and routed by what their base
/// layer is compatible with.
final class DynamicHDRTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func videoTrack(of name: String) async throws -> UmbelTrack {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture(name)))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    return try XCTUnwrap(tracks.first { $0.kind == .video })
  }

  func testTheRouteFollowsTheBaseLayersCompatibility() {
    let cases: [(profile: Int, compatibility: Int, system: Bool, base: UmbelDVBaseLayer?)] = [
      (5, 0, true, nil),
      (8, 1, false, .hdr10),
      (8, 4, false, .hlg),
      (8, 2, false, .sdr),
      (7, 6, false, .hdr10),
      (8, 9, false, nil),
    ]
    for c in cases {
      let dv = UmbelDynamicHDR.dv(profile: c.profile, level: 3, compatibility: c.compatibility)
      XCTAssertEqual(dv.requiresSystemDisplay, c.system, "profile \(c.profile), compatibility \(c.compatibility)")
      XCTAssertEqual(dv.baseLayer, c.base, "profile \(c.profile), compatibility \(c.compatibility)")
    }
  }

  func testLabelsAreNeutral() {
    let cases: [(Int, Int, String)] = [(5, 0, "DV P5"), (8, 1, "DV P8.1"), (8, 4, "DV P8.4"), (7, 6, "DV P7")]
    for (profile, compatibility, label) in cases {
      let dv = UmbelDynamicHDR.dv(profile: profile, level: 3, compatibility: compatibility)
      XCTAssertEqual(dv.label, label)
      XCTAssertNotNil(dv.label.range(of: #"^DV P[0-9]+(\.[0-9])?$"#, options: .regularExpression))
    }
  }

  func testTheBaseLayersColourIsTheOneItsCompatibilityNames() {
    XCTAssertEqual(UmbelDVBaseLayer.hdr10.transfer, .pq)
    XCTAssertEqual(UmbelDVBaseLayer.hlg.transfer, .hlg)
    XCTAssertEqual(UmbelDVBaseLayer.sdr.transfer, .sdr)
  }

  func testAnUntaggedBaseLayerTakesItsCompatibilitysColour() async throws {
    let track = try await videoTrack(of: "dv_p81_untagged.mp4")
    XCTAssertEqual(track.video?.transfer, .pq)
    XCTAssertEqual(track.video?.dynamicHDR, .dv(profile: 8, level: 3, compatibility: 1))
  }

  func testTaggedFilesKeepTheirOwn() async throws {
    let track = try await videoTrack(of: "dv_p84.mp4")
    XCTAssertEqual(track.video?.transfer, .hlg)
    XCTAssertEqual(track.video?.dynamicHDR, .dv(profile: 8, level: 3, compatibility: 4))
  }

  func testProfileFiveIsMarkedForTheSystem() async throws {
    let track = try await videoTrack(of: "dv_p5.mp4")
    XCTAssertEqual(track.video?.dynamicHDR?.requiresSystemDisplay, true)
    XCTAssertEqual(track.video?.dynamicHDR?.label, "DV P5")
  }

  func testAPlainFileHasNoDynamicHDR() async throws {
    let track = try await videoTrack(of: "hdr10_pq.mp4")
    XCTAssertNil(track.video?.dynamicHDR)
  }
}
