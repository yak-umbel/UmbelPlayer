import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// The pieces together, with the real system player: a playlist written
/// whole, fragments made from the film's packets, served on loopback.
final class GeneratedSegmentPlaybackTests: XCTestCase {
  @MainActor
  func testTheSystemPlayerPlaysGeneratedSegmentsAndSeeks() async throws {
    let (server, playlist, shift) = try await ServedEAC3.serve()
    addTeardownBlock { await server.unregister(playlist.deletingLastPathComponent()) }
    let player = AVPlayer(url: playlist)
    player.volume = 0
    addTeardownBlock { @MainActor in player.pause() }
    player.play()
    try await ServedEAC3.waitUntilPlaying(player)

    // This check now and then finds the clock short on the hosted runner, only
    // when the whole suite runs, and why is not known. So the player is looked at
    // every 50 ms for the second, and what was seen is shown only if it comes out short.
    let first = player.currentTime().seconds
    var seen: [String] = []
    let started = ContinuousClock.now
    while (ContinuousClock.now - started).inSeconds < 1 {
      seen.append(Self.describe(player, after: (ContinuousClock.now - started).inSeconds))
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let elapsed = (ContinuousClock.now - started).inSeconds
    let advanced = player.currentTime().seconds - first
    XCTAssertEqual(advanced, elapsed, accuracy: 0.2,
                   "the clock runs; the player, every 50 ms:\n" + seen.joined(separator: "\n"))

    let target = CMTime(seconds: 7, preferredTimescale: 600)
    let done = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    XCTAssertTrue(done)
    let landed = player.currentTime().seconds
    // The player's time is the shifted track's or the film's: recorded here,
    // and the timeline maps whichever it is.
    print("seek to 7.000 landed at \(landed); shift \(shift.seconds)")
    XCTAssertEqual(landed, 7.0, accuracy: 0.05)
  }

  /// One look at the player: its time, rate and state, why it waits if it does,
  /// and how far it has loaded.
  @MainActor
  private static func describe(_ player: AVPlayer, after seconds: Double) -> String {
    let loaded = player.currentItem?.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? -1
    let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
    return String(
      format: "%4dms  time %7.3f  rate %.1f  status %d  waiting %@  loaded to %.1f",
      Int(seconds * 1000), player.currentTime().seconds, player.rate,
      player.timeControlStatus.rawValue, waiting, loaded)
  }
}
