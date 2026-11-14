import XCTest
@testable import UmbelCore

final class HLSMasterPlaylistTests: XCTestCase {
  private let base = URL(string: "https://cdn.invalid/show/master.m3u8")!

  private func parse(_ lines: [String]) throws -> HLSMasterPlaylist {
    try HLSMasterPlaylist.parse(lines.joined(separator: "\n"), base: base)
  }

  func testVariantsAndTheirAttributes() throws {
    let master = try parse([
      "#EXTM3U",
      "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO=\"a\"", "low/index.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=2400000", "https://other.invalid/high.m3u8",
    ])
    XCTAssertEqual(master.variants.map(\.bandwidth), [800_000, 2_400_000])
    XCTAssertEqual(master.variants.map(\.url.absoluteString), [
      "https://cdn.invalid/show/low/index.m3u8", "https://other.invalid/high.m3u8",
    ])
    XCTAssertEqual(master.variants.map(\.audioGroup), ["a", nil])
  }

  func testTheHighestBandwidthIsChosen() throws {
    let master = try parse([
      "#EXTM3U",
      "#EXT-X-STREAM-INF:BANDWIDTH=300000", "a.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=900000", "b.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=600000", "c.m3u8",
    ])
    XCTAssertEqual(master.best()?.url.lastPathComponent, "b.m3u8")
  }

  /// Sound in a playlist of its own is not something this demuxer joins up;
  /// sound listed without an address is the variant's own, muxed in.
  func testSeparateAudioIsSeen() throws {
    let separate = try parse([
      "#EXTM3U",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"en\",URI=\"audio/en.m3u8\"",
      "#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"a\"", "v.m3u8",
    ])
    XCTAssertTrue(separate.needsSeparateAudio(try XCTUnwrap(separate.best())))

    let muxed = try parse([
      "#EXTM3U",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"en\",DEFAULT=YES",
      "#EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO=\"a\"", "v.m3u8",
    ])
    XCTAssertFalse(muxed.needsSeparateAudio(try XCTUnwrap(muxed.best())))
  }

  func testAttributesWithCommasInQuotes() throws {
    let master = try parse([
      "#EXTM3U",
      "#EXT-X-STREAM-INF:CODECS=\"avc1.64001f,mp4a.40.2\",BANDWIDTH=500000,AUDIO=\"x\"", "v.m3u8",
    ])
    XCTAssertEqual(master.variants.first?.bandwidth, 500_000)
    XCTAssertEqual(master.variants.first?.audioGroup, "x")
  }

  /// What FFmpeg's reading is handed: the variant to play and one of its
  /// sound renditions — the default — and nothing else. Handed the whole,
  /// it opens every variant and rendition at once.
  func testAMasterForTheVariantPlayedOnly() throws {
    let master = try parse([
      "#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"lo\",NAME=\"en\",DEFAULT=YES,URI=\"a/lo.m3u8\"",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"hi\",NAME=\"fr\",DEFAULT=NO,URI=\"a/hi-fr.m3u8\"",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"hi\",NAME=\"en\",DEFAULT=YES,URI=\"a/hi-en.m3u8\"",
      "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"s\",NAME=\"en\",URI=\"s/en.m3u8\"",
      "#EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO=\"lo\",SUBTITLES=\"s\"", "v/lo.m3u8",
      "#EXT-X-STREAM-INF:BANDWIDTH=900,AUDIO=\"hi\",SUBTITLES=\"s\"", "v/hi.m3u8",
      "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=50,URI=\"v/iframes.m3u8\"",
    ])
    let best = try XCTUnwrap(master.best())
    let text = master.playing(best)
    let trimmed = try parse(text.components(separatedBy: "\n"))
    XCTAssertEqual(trimmed.variants.map(\.url.lastPathComponent), ["hi.m3u8"])
    XCTAssertEqual(trimmed.renditions.map { $0.url?.lastPathComponent }, ["hi-en.m3u8"])
    XCTAssertFalse(text.contains("SUBTITLES=\"s\"") || text.contains("iframes"))
    XCTAssertTrue(text.hasPrefix("#EXTM3U"))
  }

  func testAMediaPlaylistIsNotAMaster() {
    XCTAssertThrowsError(try parse(["#EXTM3U", "#EXTINF:2,", "a.ts"]))
  }
}
