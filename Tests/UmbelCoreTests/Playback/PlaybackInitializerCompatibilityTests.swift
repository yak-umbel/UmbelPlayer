import CoreMedia
import UmbelCore
import XCTest

final class PlaybackInitializerCompatibilityTests: XCTestCase {
  func testDemuxInitializerRetainsItsOriginalFunctionType() async throws {
    let factory: (any UmbelSource, DemuxConfiguration) -> DemuxSession = DemuxSession.init
    let demux = factory(try UmbelFileSource(url: fixture()), .init())
    addTeardownBlock { await demux.close() }
    try await demux.open()
    let tracks = await demux.tracks
    XCTAssertTrue(tracks.contains { $0.kind == .audio })
  }

  func testClockInitializerRetainsItsOriginalFunctionType() async {
    let factory: (any HostTimeSource, (any ClockFollower)?) -> PresentationClock = PresentationClock.init
    let clock = factory(SystemHostTimeSource(), nil)
    await clock.reset(to: CMTime(seconds: 12, preferredTimescale: 600))
    let now = await clock.now()
    XCTAssertEqual(now.seconds, 12)
  }

  func testSessionInitializerRetainsItsOriginalFunctionType() async throws {
    let factory: (
      any UmbelSource, (any AudioOutput)?, (any VideoRenderer)?, Bool, any HostTimeSource,
      DemuxConfiguration, BufferingConfiguration, CachedAudioConfiguration,
      UmbelVideoDecodingMode, UmbelObjectAudioMode
    ) -> PlaybackSession = PlaybackSession.init
    let session = factory(
      try UmbelFileSource(url: fixture()), nil, nil, true, SystemHostTimeSource(),
      .init(), .init(), .init(), .synchronous, .automatic)
    addTeardownBlock { await session.stop() }
    try await session.load()
    let phase = await session.phase
    XCTAssertEqual(phase, .paused)
  }

  /// Public, whichever way the session is made; not asking is the default.
  func testSessionsTakeTheVideoDecoderConfigurationFromEitherInitializer() async throws {
    let asked = UmbelVideoDecoderConfiguration(preference: .software, softwareThreadCount: 2)
    let plain = PlaybackSession(source: try UmbelFileSource(url: fixture()), videoDecoder: asked)
    let full = PlaybackSession(
      source: try UmbelFileSource(url: fixture()), videoPolicy: nil, videoDecoder: asked)
    let unasked = PlaybackSession(source: try UmbelFileSource(url: fixture()))
    let kept = await [plain.videoDecoderConfiguration, full.videoDecoderConfiguration]
    let defaulted = await unasked.videoDecoderConfiguration
    XCTAssertEqual(kept, [asked, asked])
    XCTAssertEqual(defaulted, UmbelVideoDecoderConfiguration())
    XCTAssertEqual(defaulted.preference, .hardware)
    XCTAssertNil(defaulted.softwareThreadCount)
  }

  private func fixture() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/audio_only.m4a")
  }
}
