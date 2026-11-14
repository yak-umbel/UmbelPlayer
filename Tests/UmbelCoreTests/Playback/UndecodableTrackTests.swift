import CoreMedia
import Metal
import UmbelFFmpegSupport
import XCTest
@testable import UmbelCore

/// A track no decoder here reads — AC-4 in the fixtures — must not cost the
/// film: automatic choice passes over it, choosing it says why it cannot
/// play, and a picture whose only sound is such a track still plays.
final class UndecodableTrackTests: XCTestCase {
  private final class HeldHostTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func track(_ index: Int32, isDefault: Bool, decodable: Bool) -> UmbelTrack {
    UmbelTrack(
      id: UmbelTrack.ID(rawValue: index), kind: .audio, codecName: decodable ? "aac" : "ac4",
      language: nil, title: nil, isDefault: isDefault, isForced: false,
      video: nil, audio: nil, isDecodable: decodable)
  }

  // ── The rule ─────────────────────────────────────────

  func testAnUndecodableDefaultIsPassedOver() {
    let tracks = [track(1, isDefault: true, decodable: false), track(2, isDefault: false, decodable: true)]
    XCTAssertEqual(TrackPreference.preferred(of: .audio, in: tracks)?.id, UmbelTrack.ID(rawValue: 2))
  }

  func testTheDefaultStillWinsAmongDecodableTracks() {
    let tracks = [
      track(1, isDefault: false, decodable: false), track(2, isDefault: false, decodable: true),
      track(3, isDefault: true, decodable: true),
    ]
    XCTAssertEqual(TrackPreference.preferred(of: .audio, in: tracks)?.id, UmbelTrack.ID(rawValue: 3))
  }

  func testNothingIsPickedWhenNoTrackCanBeDecoded() {
    XCTAssertNil(TrackPreference.preferred(of: .audio, in: [track(1, isDefault: true, decodable: false)]))
  }

  func testMappingCarriesWhetherADecoderExists() throws {
    let info = FFmpegStreamInfo(
      index: 1, mediaType: .audio, codecName: "ac4", language: nil, title: nil,
      isDefault: true, isForced: false, width: 0, height: 0, frameRateNum: 0, frameRateDen: 1,
      channelCount: 6, sampleRate: 48_000, hasDecoder: false)
    let mapped = try XCTUnwrap(TrackMapping.track(from: info))
    XCTAssertFalse(mapped.isDecodable)
  }

  // ── Real files ───────────────────────────────────────

  private func loaded(_ name: String, renderer: OffscreenVideoRenderer? = nil) async throws -> PlaybackSession {
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture(name)),
      audioOutput: VirtualAudioOutput(hostTime: HeldHostTime()),
      videoRenderer: renderer, hostTime: HeldHostTime())
    try await session.load()
    return session
  }

  /// ac4_then_aac.mp4: its first audio track is AC-4 and marked default.
  func testAFileWhoseDefaultSoundCannotBeDecodedPlaysItsOtherTrack() async throws {
    let session = try await loaded("ac4_then_aac.mp4")
    addTeardownBlock { await session.stop() }
    let audio = await session.tracks.filter { $0.kind == .audio }
    XCTAssertEqual(audio.map(\.codecName), ["ac4", "aac"])
    XCTAssertEqual(audio.map(\.isDecodable), [false, true])
    let selected = await session.selectedAudioTrack
    XCTAssertEqual(selected, audio[1].id)
  }

  func testChoosingAnUndecodableTrackSaysWhyAndKeepsTheCurrentOne() async throws {
    let session = try await loaded("ac4_then_aac.mp4")
    addTeardownBlock { await session.stop() }
    let audio = await session.tracks.filter { $0.kind == .audio }
    do {
      try await session.selectAudioTrack(audio[0].id)
      XCTFail("an AC-4 track cannot be chosen")
    } catch UmbelError.unsupportedCodec(let codec) {
      XCTAssertEqual(codec, "ac4")
    }
    let selected = await session.selectedAudioTrack
    XCTAssertEqual(selected, audio[1].id, "the sound playing before stays")
  }

  /// ac4_only.mp4: a picture whose only sound is AC-4 plays without sound.
  func testThePictureStillPlaysWhenNoSoundCanBeDecoded() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.05, preferredTimescale: 600))
    let session = try await loaded("ac4_only.mp4", renderer: renderer)
    addTeardownBlock { await session.stop() }
    let selected = await session.selectedAudioTrack
    XCTAssertNil(selected)
    try await session.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600))
    var shown: PresentedFrame?
    for _ in 0..<100 where shown == nil {
      shown = try await session.renderVideoFrame()
      if shown == nil { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    XCTAssertNotNil(shown, "the picture plays")
  }
}
