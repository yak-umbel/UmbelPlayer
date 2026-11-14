import CoreMedia
import XCTest
@testable import UmbelCore

private enum Fixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }
}

/// How loud a session plays, and muting: handed to the output as set, held
/// to 0...1, and kept through what else the session does.
final class PlaybackVolumeTests: XCTestCase {
  private let output = VirtualAudioOutput(hostTime: SystemHostTimeSource())

  private func session(_ name: String = "seek_grid.mp4", sound: Bool = true) throws -> PlaybackSession {
    PlaybackSession(source: try UmbelFileSource(url: Fixture.url(name)), audioOutput: sound ? output : nil)
  }

  func testSetBeforeLoadingReachesTheOutput() async throws {
    let session = try session()
    await session.setVolume(0.3)
    await session.setMuted(true)
    try await session.load()
    addTeardownBlock { await session.stop() }
    let volume = await output.volume
    let muted = await output.isMuted
    XCTAssertEqual(volume, 0.3)
    XCTAssertTrue(muted)
  }

  func testTheVolumeIsHeldToZeroToOne() async throws {
    let session = try session()
    await session.setVolume(1.5)
    var volume = await session.volume
    XCTAssertEqual(volume, 1)
    await session.setVolume(-1)
    volume = await session.volume
    XCTAssertEqual(volume, 0)
  }

  func testANumberThatIsNoNumberIsLeftOut() async throws {
    let session = try session()
    await session.setVolume(0.4)
    await session.setVolume(.nan)
    await session.setVolume(.infinity)
    let volume = await session.volume
    XCTAssertEqual(volume, 0.4)
  }

  /// Muted, the volume can still change: unmuted, the new one plays.
  func testChangingTheVolumeWhileMutedStaysMuted() async throws {
    let session = try session()
    await session.setMuted(true)
    await session.setVolume(0.6)
    var muted = await output.isMuted
    XCTAssertTrue(muted)
    await session.setMuted(false)
    muted = await output.isMuted
    let volume = await output.volume
    XCTAssertFalse(muted)
    XCTAssertEqual(volume, 0.6)
  }

  func testTheLevelStaysThroughAnAudioTrackSwitch() async throws {
    let session = try session("multi_track.mkv")
    try await session.load()
    addTeardownBlock { await session.stop() }
    await session.setVolume(0.25)
    let second = await session.tracks.filter { $0.kind == .audio }[1]
    try await session.selectAudioTrack(second.id)
    let volume = await output.volume
    XCTAssertEqual(volume, 0.25)
  }

  func testWithoutAnOutputTheLevelIsOnlyKept() async throws {
    let session = try session(sound: false)
    await session.setVolume(0.5)
    await session.setMuted(true)
    let volume = await session.volume
    let muted = await session.isMuted
    XCTAssertEqual(volume, 0.5)
    XCTAssertTrue(muted)
  }
}
