import XCTest
@testable import UmbelCore

/// Segments that are sound alone — "packed audio": raw AAC, MP3, AC-3 or
/// E-AC-3 frames, usually behind an ID3 tag — are told by their first
/// bytes, so a playlist of them goes to FFmpeg's reading at once rather
/// than after reading as a transport stream until the probe gives up.
final class HLSPackedAudioTests: XCTestCase {
  func testSoundAloneIsTold() {
    XCTAssertTrue(HLSPackedAudio.isPackedAudio(Data([0x49, 0x44, 0x33, 0x04, 0, 0])), "ID3")
    XCTAssertTrue(HLSPackedAudio.isPackedAudio(Data([0xFF, 0xF1, 0x50, 0x80])), "ADTS")
    XCTAssertTrue(HLSPackedAudio.isPackedAudio(Data([0xFF, 0xFB, 0x90, 0x00])), "MPEG audio")
    XCTAssertTrue(HLSPackedAudio.isPackedAudio(Data([0x0B, 0x77, 0x00, 0x00])), "AC-3 and E-AC-3")
  }

  func testEverythingElseIsNot() {
    XCTAssertFalse(HLSPackedAudio.isPackedAudio(Data([0x47, 0x40, 0x00, 0x10])), "a transport stream")
    XCTAssertFalse(HLSPackedAudio.isPackedAudio(Data([0x89, 0x50, 0x4E, 0x47])), "a disguise")
    XCTAssertFalse(HLSPackedAudio.isPackedAudio(Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74])), "MP4")
    XCTAssertFalse(HLSPackedAudio.isPackedAudio(Data()))
  }
}
