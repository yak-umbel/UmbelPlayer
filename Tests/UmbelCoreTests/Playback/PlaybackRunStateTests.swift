import CoreMedia
import XCTest
@testable import UmbelCore

final class PlaybackRunStateTests: XCTestCase {
  /// Reader and feeder can both inspect the cache as the last read finishes.
  /// Once both observations finish, EOF must leave playback able to drain.
  func testConcurrentObservationsCannotHoldPlaybackAfterEndOfInput() async throws {
    for iteration in 0..<500 {
      let cache = PacketCache(configuration: .init(), measuredTrack: .init(rawValue: 1))
      let run = PlaybackRunState(
        clock: PresentationClock(hostTime: SystemHostTimeSource()),
        audioOutput: nil, cache: cache)
      try await run.setOutputsReady(true)
      try await run.setWantsToPlay(true)
      let feeders = (0..<12).map { _ in
        Task(priority: .background) { try await run.update() }
      }
      await Task.yield()
      await cache.markEndOfContent()
      try await run.update()
      for feeder in feeders { try await feeder.value }
      let running = await run.isRunning
      guard running else {
        return XCTFail("EOF left playback buffering at iteration \(iteration)")
      }
    }
  }
}
