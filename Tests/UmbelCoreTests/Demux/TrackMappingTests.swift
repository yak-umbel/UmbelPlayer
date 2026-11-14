import CoreMedia
import UmbelFFmpegSupport
import XCTest
@testable import UmbelCore

final class TrackMappingTests: XCTestCase {
  private func info(
    index: Int32 = 0,
    mediaType: FFmpegMediaType = .video,
    codecName: String = "h264",
    language: String? = "eng",
    title: String? = nil,
    isDefault: Bool = false,
    isForced: Bool = false,
    width: Int32 = 1920,
    height: Int32 = 1080,
    frameRateNum: Int32 = 25,
    frameRateDen: Int32 = 1,
    channelCount: Int32 = 0,
    sampleRate: Int32 = 0
  ) -> FFmpegStreamInfo {
    FFmpegStreamInfo(
      index: index, mediaType: mediaType, codecName: codecName,
      language: language, title: title, isDefault: isDefault, isForced: isForced,
      width: width, height: height, frameRateNum: frameRateNum, frameRateDen: frameRateDen,
      channelCount: channelCount, sampleRate: sampleRate
    )
  }

  func testVideoStreamBecomesVideoTrack() throws {
    let track = try XCTUnwrap(TrackMapping.track(from: info()))
    XCTAssertEqual(track.kind, .video)
    XCTAssertEqual(track.codecName, "h264")
    XCTAssertEqual(track.video?.width, 1920)
    XCTAssertEqual(track.video?.height, 1080)
    XCTAssertEqual(track.video?.nominalFrameRate ?? 0, 25, accuracy: 0.001)
    XCTAssertNil(track.audio)
  }

  func testAudioStreamBecomesAudioTrack() throws {
    let source = info(mediaType: .audio, codecName: "aac", width: 0, height: 0,
                      frameRateNum: 0, frameRateDen: 0, channelCount: 6, sampleRate: 48_000)
    let track = try XCTUnwrap(TrackMapping.track(from: source))
    XCTAssertEqual(track.kind, .audio)
    XCTAssertEqual(track.audio?.channelCount, 6)
    XCTAssertEqual(track.audio?.sampleRate, 48_000)
    XCTAssertNil(track.video)
  }

  func testSubtitleStreamKeepsForcedFlag() throws {
    let source = info(mediaType: .subtitle, codecName: "subrip", isForced: true,
                      width: 0, height: 0, frameRateNum: 0, frameRateDen: 0)
    let track = try XCTUnwrap(TrackMapping.track(from: source))
    XCTAssertEqual(track.kind, .subtitle)
    XCTAssertTrue(track.isForced)
    XCTAssertNil(track.video)
    XCTAssertNil(track.audio)
  }

  func testForcedFlagIsClearedForNonSubtitleTracks() throws {
    let track = try XCTUnwrap(TrackMapping.track(from: info(isForced: true)))
    XCTAssertFalse(track.isForced, "a track that is not subtitles is never forced")
  }

  func testOtherMediaTypeIsDropped() {
    XCTAssertNil(TrackMapping.track(from: info(mediaType: .other)))
  }

  func testZeroDenominatorFrameRateBecomesNil() throws {
    let track = try XCTUnwrap(TrackMapping.track(from: info(frameRateNum: 25, frameRateDen: 0)))
    XCTAssertNil(track.video?.nominalFrameRate, "a zero denominator gives no inf; it counts as not declared")
  }

  func testZeroNumeratorFrameRateBecomesNil() throws {
    let track = try XCTUnwrap(TrackMapping.track(from: info(frameRateNum: 0, frameRateDen: 1)))
    XCTAssertNil(track.video?.nominalFrameRate)
  }

  func testEmptyLanguageBecomesNil() throws {
    let track = try XCTUnwrap(TrackMapping.track(from: info(language: "")))
    XCTAssertNil(track.language, "an empty string is no language; it counts as not declared")
  }

  func testTimeConversionUsesTimeBase() {
    let time = TrackMapping.time(ticks: 90_000, num: 1, den: 90_000)
    XCTAssertEqual(time.seconds, 1.0, accuracy: 0.0001)
  }

  func testNoTimestampBecomesInvalid() {
    let time = TrackMapping.time(ticks: FFmpegPacket.noTimestamp, num: 1, den: 1000)
    XCTAssertFalse(time.isValid)
  }

  func testZeroDenominatorTimeBaseBecomesInvalid() {
    let time = TrackMapping.time(ticks: 100, num: 1, den: 0)
    XCTAssertFalse(time.isValid, "a zero denominator gives no inf")
  }

  func testZeroTicksIsValidZeroNotInvalid() {
    let time = TrackMapping.time(ticks: 0, num: 1, den: 1000)
    XCTAssertTrue(time.isValid)
    XCTAssertEqual(time, .zero)
  }
}
