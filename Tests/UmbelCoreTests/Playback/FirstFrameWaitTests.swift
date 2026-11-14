import CoreMedia
import XCTest
@testable import UmbelCore

final class FirstFrameWaitTests: XCTestCase {
  private let audio = UmbelTrack.ID(rawValue: 1)
  private let video = UmbelTrack.ID(rawValue: 0)

  private func packet(_ track: UmbelTrack.ID, at seconds: Double) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: 4),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 600),
      duration: .invalid, isKeyframe: true)
  }

  private func waiting(from seconds: Double = 10) -> FirstFrameWait {
    FirstFrameWait(awaiting: [audio, video], from: CMTime(seconds: seconds, preferredTimescale: 600))
  }

  func testNothingToWaitForIsReady() {
    XCTAssertTrue(FirstFrameWait().isReady)
    XCTAssertTrue(FirstFrameWait(awaiting: [], from: .zero).isReady)
  }

  func testReadyOnceEveryTrackHasHandedAFrameOn() {
    var wait = waiting()
    XCTAssertFalse(wait.decoded(packet(audio, at: 10), handingOn: 1))
    XCTAssertFalse(wait.isReady)
    XCTAssertFalse(wait.decoded(packet(video, at: 9), handingOn: 0), "decoding up to the target")
    XCTAssertTrue(wait.decoded(packet(video, at: 10.1), handingOn: 1))
    XCTAssertTrue(wait.isReady)
    XCTAssertFalse(wait.decoded(packet(video, at: 10.2), handingOn: 1), "over once")
  }

  func testATrackThatEndsIsReady() {
    var wait = waiting()
    _ = wait.decoded(packet(audio, at: 10), handingOn: 1)
    XCTAssertTrue(wait.finished(video))
  }

  /// A stream yielding nothing must not hold the sound back for good.
  func testATrackYieldingNothingIsGivenUpOnTwoSecondsIn() {
    var wait = waiting()
    _ = wait.decoded(packet(audio, at: 10), handingOn: 1)
    XCTAssertFalse(wait.decoded(packet(video, at: 12), handingOn: 0))
    XCTAssertTrue(wait.decoded(packet(video, at: 12.1), handingOn: 0))
  }

  func testATrackSwitchedAwayIsNotWaitedFor() {
    var wait = waiting()
    XCTAssertFalse(wait.keep(only: [audio, video]), "nothing changed")
    _ = wait.decoded(packet(video, at: 10), handingOn: 1)
    XCTAssertTrue(wait.keep(only: [video]), "sound switched off")
  }

  /// A track given up on can still hand on a first frame later, and that
  /// frame counts as one: at the byte budget it may be all there is to go
  /// on with.
  func testAFrameAfterGivingUpIsStillAFirstFrame() {
    var wait = waiting()
    XCTAssertFalse(wait.decoded(packet(video, at: 12.1), handingOn: 0), "given up on; the sound is still awaited")
    XCTAssertFalse(wait.firstFrame(from: video, handingOn: 0))
    XCTAssertTrue(wait.firstFrame(from: video, handingOn: 1))
    XCTAssertFalse(wait.firstFrame(from: video, handingOn: 1), "only the first")
    XCTAssertTrue(wait.firstFrame(from: audio, handingOn: 1))
  }

  /// Switched away and back, a track's next frame is a first one again.
  func testARerouteForgetsTheFirstFramesOfTracksNoLongerRouted() {
    var wait = waiting()
    XCTAssertTrue(wait.firstFrame(from: video, handingOn: 1))
    _ = wait.keep(only: [audio])
    XCTAssertTrue(wait.firstFrame(from: video, handingOn: 1))
  }

  func testOnlyAwaitedTracksCount() {
    var wait = FirstFrameWait(awaiting: [video], from: .zero)
    XCTAssertFalse(wait.decoded(packet(audio, at: 0), handingOn: 1))
    XCTAssertFalse(wait.finished(audio))
    XCTAssertFalse(wait.isReady)
  }
}
