import XCTest
@testable import UmbelCore

final class SubtitleSelectionTests: XCTestCase {
  private func track(
    _ id: Int32, _ kind: UmbelTrack.Kind, language: String?,
    isDefault: Bool = false, isForced: Bool = false
  ) -> UmbelTrack {
    UmbelTrack(
      id: UmbelTrack.ID(rawValue: id), kind: kind, codecName: "x", language: language,
      title: nil, isDefault: isDefault, isForced: isForced, video: nil, audio: nil)
  }

  /// MKV writes bibliographic codes, MP4 terminological ones, newer files
  /// two-letter tags with regions. All of them name the same language.
  func testLanguageCodesNormalise() {
    let chinese = ["chi", "zho", "zh", "ZH", "zh-CN"].map(SubtitleSelection.normalizedLanguage)
    XCTAssertEqual(Set(chinese), ["zh"])
    XCTAssertEqual(SubtitleSelection.normalizedLanguage("ger"), SubtitleSelection.normalizedLanguage("deu"))
    XCTAssertEqual(SubtitleSelection.normalizedLanguage("en-US"), "en")
  }

  /// "Undetermined" is not a language; two unknowns must not match each other.
  func testUndeterminedIsNoLanguage() {
    XCTAssertNil(SubtitleSelection.normalizedLanguage(nil))
    XCTAssertNil(SubtitleSelection.normalizedLanguage(""))
    XCTAssertNil(SubtitleSelection.normalizedLanguage("und"))
    XCTAssertNil(SubtitleSelection.normalizedLanguage("mul"))
  }

  func testForcedTrackInTheAudioLanguageIsChosen() {
    let tracks = [
      track(1, .audio, language: "jpn"),
      track(2, .subtitle, language: "eng", isForced: true),
      track(3, .subtitle, language: "ja", isForced: true),
    ]
    XCTAssertEqual(SubtitleSelection.forcedTrack(for: tracks[0], in: tracks)?.id.rawValue, 3)
  }

  /// A default flag is not a reason to show subtitles; only forced ones are.
  func testOrdinaryTracksAreNeverChosen() {
    let tracks = [
      track(1, .audio, language: "eng"),
      track(2, .subtitle, language: "eng", isDefault: true),
    ]
    XCTAssertNil(SubtitleSelection.forcedTrack(for: tracks[0], in: tracks))
  }

  func testNoMatchMeansNothing() {
    let tracks = [
      track(1, .audio, language: "eng"),
      track(2, .subtitle, language: "chi", isForced: true),
      track(3, .subtitle, language: nil, isForced: true),
    ]
    XCTAssertNil(SubtitleSelection.forcedTrack(for: tracks[0], in: tracks))
    XCTAssertNil(SubtitleSelection.forcedTrack(for: nil, in: tracks), "no audio, no language to match")
  }
}
