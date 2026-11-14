import XCTest
@testable import UmbelCore

final class HLSMediaPlaylistTests: XCTestCase {
  private let base = URL(string: "https://cdn.invalid/path/index.m3u8?token=abc")!

  private func parse(_ lines: [String]) throws -> HLSMediaPlaylist {
    try HLSMediaPlaylist.parse(lines.joined(separator: "\n"), base: base)
  }

  func testSegmentsTheirStartsAndTheDuration() throws {
    let playlist = try parse([
      "#EXTM3U", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:7",
      "#EXTINF:6.48,", "a.ts", "#EXTINF:1.52,", "b.ts", "#EXT-X-ENDLIST",
    ])
    XCTAssertEqual(playlist.targetDuration, 6)
    XCTAssertEqual(playlist.mediaSequence, 7)
    XCTAssertEqual(playlist.segments.map(\.start), [0, 6.48])
    XCTAssertEqual(playlist.duration, 8, accuracy: 1e-9)
    XCTAssertTrue(playlist.isEnded)
  }

  /// Each discontinuity tag starts a new run; the tag before the first
  /// segment does not make the first run any different.
  func testDiscontinuitiesStartRuns() throws {
    let playlist = try parse([
      "#EXTM3U", "#EXT-X-DISCONTINUITY", "#EXTINF:2,", "a", "#EXTINF:2,", "b",
      "#EXT-X-DISCONTINUITY", "#EXTINF:2,", "ad", "#EXT-X-DISCONTINUITY", "#EXTINF:2,", "c",
    ])
    XCTAssertEqual(playlist.segments.map(\.run), [0, 0, 1, 2])
  }

  func testAddressesResolveAgainstTheBase() throws {
    let playlist = try parse([
      "#EXTM3U", "#EXTINF:1,", "seg 1.ts", "#EXTINF:1,", "/root/seg2.ts?x=1",
      "#EXTINF:1,", "https://other.invalid/seg3", "#EXTINF:1,", "../up.ts",
    ])
    XCTAssertEqual(playlist.segments.map(\.url.absoluteString), [
      "https://cdn.invalid/path/seg%201.ts",
      "https://cdn.invalid/root/seg2.ts?x=1",
      "https://other.invalid/seg3",
      "https://cdn.invalid/up.ts",
    ])
  }

  func testCommonSlipsAreForgiven() throws {
    let text = "\u{FEFF}#EXTM3U\r\n#EXTINF:4\r\n\r\na.ts\r\n#EXT-X-UNKNOWN:1\r\n# a comment\r\n"
      + "#EXTINF:3,title\r\nb.ts\r\n"
    let playlist = try HLSMediaPlaylist.parse(text, base: base)
    XCTAssertEqual(playlist.segments.map(\.duration), [4, 3])
    XCTAssertFalse(playlist.isEnded)
  }

  func testByteRanges() throws {
    let playlist = try parse([
      "#EXTM3U", "#EXTINF:1,", "#EXT-X-BYTERANGE:100@0", "all.ts",
      "#EXTINF:1,", "#EXT-X-BYTERANGE:50", "all.ts",
    ])
    XCTAssertEqual(playlist.segments.map(\.byteRange), [0..<100, 100..<150])
  }

  func testWhatThisPartDoesNotTakeIsRefused() {
    XCTAssertThrowsError(try parse(["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=1", "v.m3u8"])) {
      XCTAssertEqual($0 as? HLSMediaPlaylist.ParseError, .masterPlaylist)
    }
    XCTAssertThrowsError(try parse([
      "#EXTM3U", "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"", "#EXTINF:1,", "a.ts",
    ])) {
      XCTAssertEqual($0 as? HLSMediaPlaylist.ParseError, .unsupported("EXT-X-KEY METHOD=SAMPLE-AES"))
    }
    XCTAssertThrowsError(try parse([
      "#EXTM3U", "#EXT-X-KEY:METHOD=AES-128,URI=\"k\"", "#EXTINF:1,",
      "#EXT-X-BYTERANGE:100@0", "a.ts",
    ]), "a byte range of an encrypted file starts mid-chain")
    XCTAssertThrowsError(try parse([
      "#EXTM3U", "#EXT-X-KEY:METHOD=AES-128,URI=\"k\"", "#EXT-X-MAP:URI=\"i.mp4\"",
      "#EXTINF:1,", "a.m4s",
    ])) {
      XCTAssertEqual($0 as? HLSMediaPlaylist.ParseError, .unsupported("EXT-X-MAP with EXT-X-KEY"))
    }
    XCTAssertNoThrow(try parse(["#EXTM3U", "#EXT-X-KEY:METHOD=NONE", "#EXTINF:1,", "a.ts"]))
    XCTAssertThrowsError(try parse(["#EXTM3U", "#EXT-X-ENDLIST"])) {
      XCTAssertEqual($0 as? HLSMediaPlaylist.ParseError, .noSegments)
    }
    XCTAssertThrowsError(try parse(["<html>"])) {
      XCTAssertEqual($0 as? HLSMediaPlaylist.ParseError, .notAPlaylist)
    }
  }

  /// A key applies to the segments after it, until another says otherwise;
  /// with no IV named, a segment's sequence number is its IV.
  func testKeysApplyToTheSegmentsAfterThem() throws {
    let playlist = try parse([
      "#EXTM3U", "#EXT-X-MEDIA-SEQUENCE:5",
      "#EXT-X-KEY:METHOD=AES-128,URI=\"k1\",IV=0x0000000000000000000000000000000A",
      "#EXTINF:1,", "a.ts",
      "#EXT-X-KEY:METHOD=AES-128,URI=\"k2\"", "#EXTINF:1,", "b.ts",
      "#EXT-X-KEY:METHOD=NONE", "#EXTINF:1,", "c.ts",
    ])
    XCTAssertEqual(playlist.segments.map(\.sequence), [5, 6, 7])
    XCTAssertEqual(playlist.segments.map { $0.key?.url.lastPathComponent }, ["k1", "k2", nil])
    XCTAssertEqual(playlist.segments[0].key?.iv, Data(repeating: 0, count: 15) + Data([10]))
    XCTAssertNil(playlist.segments[1].key?.iv)
  }

  /// An initialisation segment applies to the segments after it; a new one
  /// starts a run of its own, as a discontinuity would.
  func testMapsCarryOverAndANewOneStartsARun() throws {
    let playlist = try parse([
      "#EXTM3U", "#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"720@0\"",
      "#EXTINF:2,", "a.m4s", "#EXTINF:2,", "b.m4s",
      "#EXT-X-MAP:URI=\"init2.mp4\"", "#EXTINF:2,", "c.m4s",
    ])
    XCTAssertEqual(playlist.segments.map { $0.map?.url.lastPathComponent }, ["init.mp4", "init.mp4", "init2.mp4"])
    XCTAssertEqual(playlist.segments.first?.map?.byteRange, 0..<720)
    XCTAssertEqual(playlist.segments.map(\.run), [0, 0, 1])
  }

  func testRecognisingAPlaylistByItsFirstBytes() {
    XCTAssertTrue(HLSMediaPlaylist.looksLikePlaylist(Data("\u{FEFF}  #EXTM3U\n".utf8)))
    XCTAssertFalse(HLSMediaPlaylist.looksLikePlaylist(Data([0x47, 0x40, 0x00])))
    XCTAssertFalse(HLSMediaPlaylist.looksLikePlaylist(Data()))
  }

  func testFindingTheSegmentForATime() throws {
    let playlist = try parse(["#EXTM3U", "#EXTINF:2,", "a", "#EXTINF:2,", "b", "#EXTINF:2,", "c"])
    XCTAssertEqual(playlist.segmentIndex(at: 0), 0)
    XCTAssertEqual(playlist.segmentIndex(at: 3.9), 1)
    XCTAssertEqual(playlist.segmentIndex(at: 4), 2)
    XCTAssertEqual(playlist.segmentIndex(at: 99), 2, "past the end: the last")
    XCTAssertEqual(playlist.segmentIndex(at: -1), 0)
  }

  /// A long film cut small: tens of thousands of lines.
  func testALongPlaylistParsesQuickly() throws {
    var lines = ["#EXTM3U"]
    for index in 0..<20_000 { lines += ["#EXTINF:4.000,", "segment-\(index).ts"] }
    let started = Date()
    let playlist = try parse(lines)
    XCTAssertEqual(playlist.segments.count, 20_000)
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
  }
}
