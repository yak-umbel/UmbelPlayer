import CoreMedia
import XCTest
@testable import UmbelCore

/// The sound track's packets gathered into segments as reading brings them,
/// for the system player to ask for by number.
final class SegmentStoreTests: XCTestCase {
  /// Four 32 ms frames a segment, nine segments, starting 5 ms early.
  private static let plan = SegmentPlan(
    frameDuration: CMTime(value: 1536, timescale: 48_000), framesPerSegment: 4,
    duration: CMTime(seconds: 1.1, preferredTimescale: 1_000), shift: CMTime(value: 5, timescale: 1_000))

  private func store(window: Int = 2, keepBehind: Int = 2) -> SegmentStore {
    SegmentStore(plan: Self.plan, window: window, keepBehind: keepBehind)
  }

  /// Frame `n` as a container gives it: in milliseconds, 5 ms early.
  private static func packet(_ frame: Int) -> DemuxPacket {
    DemuxPacket(
      trackID: .init(rawValue: 1), data: Data([UInt8(truncatingIfNeeded: frame)]),
      presentationTime: CMTime(value: Int64(frame * 32 - 5), timescale: 1_000),
      decodeTime: .invalid, duration: CMTime(value: 32, timescale: 1_000), isKeyframe: true)
  }

  private static func frames(_ packets: [DemuxPacket]) -> [Int] { packets.map { Int($0.data[0]) } }

  private static func append(_ frames: ClosedRange<Int>, to store: SegmentStore) async throws {
    for frame in frames { try await store.append(packet(frame)) }
  }

  /// Fails rather than hangs when `operation` does not finish soon.
  private static func soon<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return nil
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() ?? nil else { throw Late() }
      return value
    }
  }

  private struct Late: Error {}

  private static func pause() async throws { try await Task.sleep(nanoseconds: 50_000_000) }

  // ── Ready ───────────────────────────────────────────

  func testASegmentIsReadyOnceItsLastFrameArrives() async throws {
    let store = store()
    try await Self.append(0...3, to: store)
    let packets = try await Self.soon { try await store.packets(of: 0) }
    XCTAssertEqual(Self.frames(packets), [0, 1, 2, 3])
  }

  func testARequestWaitsForItsSegment() async throws {
    let store = store()
    let request = Task { try await store.packets(of: 1) }
    try await Self.append(0...5, to: store)
    try await Self.pause()
    let waiting = await store.isWaiting
    XCTAssertTrue(waiting, "frames 6 and 7 are still to come")
    // A later segment's first packet: the one asked for is complete as it is.
    try await store.append(Self.packet(8))
    let packets = try await Self.soon { try await request.value }
    XCTAssertEqual(Self.frames(packets), [4, 5])
    let idle = await store.isWaiting
    XCTAssertFalse(idle)
  }

  func testTheEndCompletesWhatIsLeft() async throws {
    let store = store()
    try await Self.append(0...1, to: store)
    await store.finish()
    let packets = try await Self.soon { try await store.packets(of: 0) }
    XCTAssertEqual(Self.frames(packets), [0, 1])
    let never = try await Self.soon { try await store.packets(of: 4) }
    XCTAssertEqual(never.count, 0, "listed in the playlist, never read")
  }

  /// The last segment takes whatever runs past the playlist's end, so only
  /// the end completes it.
  func testTheLastSegmentWaitsForTheEnd() async throws {
    let store = store(window: 9)
    try await Self.append(32...36, to: store)
    let request = Task { try await store.packets(of: 8) }
    try await Self.pause()
    let waiting = await store.isWaiting
    XCTAssertTrue(waiting)
    await store.finish()
    let packets = try await Self.soon { try await request.value }
    XCTAssertEqual(Self.frames(packets), [32, 33, 34, 35, 36])
  }

  func testPacketsBeforeTheTrackStartsAreLeftOut() async throws {
    let store = store()
    try await Self.append(-2...3, to: store)
    let packets = try await Self.soon { try await store.packets(of: 0) }
    XCTAssertEqual(Self.frames(packets), [0, 1, 2, 3])
  }

  // ── Seeking ─────────────────────────────────────────

  func testASeekStartsAgainAtItsSegment() async throws {
    let store = store()
    try await Self.append(0...5, to: store)
    await store.reset(to: 3)
    await assertGone(store, 0)
    try await store.append(Self.packet(10)) // segment 2: before the new start
    try await Self.append(12...15, to: store)
    let packets = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(packets), [12, 13, 14, 15])
  }

  func testARequestFromBeforeASeekIsLetGo() async throws {
    let store = store()
    let old = Task { try await store.packets(of: 1) }
    let ahead = Task { try await store.packets(of: 4) }
    try await Self.pause()
    await store.reset(to: 3)
    do {
      _ = try await Self.soon { try await old.value }
      XCTFail("reading will not come back for it")
    } catch SegmentStore.Failure.gone(let index) {
      XCTAssertEqual(index, 1)
    }
    try await Self.append(12...19, to: store)
    let packets = try await Self.soon { try await ahead.value }
    XCTAssertEqual(Self.frames(packets), [16, 17, 18, 19], "still to come after the seek")
  }

  // ── Bounds ──────────────────────────────────────────

  func testReadingWaitsUntilThePlayerAsksForMore() async throws {
    let store = store(window: 2)
    try await Self.append(0...11, to: store) // segments 0 to 2
    let far = Self.packet(12)
    let beyond = Task { try await store.append(far) }
    try await Self.pause()
    let holding = await store.isHoldingReading
    XCTAssertTrue(holding, "three segments ahead of anything asked for")
    _ = try await Self.soon { try await store.packets(of: 1) }
    _ = try await Self.soon { try await beyond.value; return true }
    let released = await store.isHoldingReading
    XCTAssertFalse(released)
  }

  /// Played again from what it kept, the player asks for nothing: where it
  /// plays lets reading on as well, or reading never got to the end.
  func testWherePlayingHasGotLetsReadingOn() async throws {
    let store = store(window: 2)
    try await Self.append(0...11, to: store)
    let far = Self.packet(16)
    let beyond = Task { try await store.append(far) }
    try await Self.pause()
    let epoch = await store.epoch
    await store.playerIsAt(CMTime(seconds: 0.2, preferredTimescale: 1_000), epoch: epoch) // segment 1
    try await Self.pause()
    var holding = await store.isHoldingReading
    XCTAssertTrue(holding, "segment 4 is more than two past segment 1")
    await store.playerIsAt(CMTime(seconds: 0.3, preferredTimescale: 1_000), epoch: epoch) // segment 2
    _ = try await Self.soon { try await beyond.value; return true }
    holding = await store.isHoldingReading
    XCTAssertFalse(holding)
  }

  /// A place told from before a seek says nothing of where the player goes.
  func testWherePlayingWasBeforeASeekIsIgnored() async throws {
    let store = store(window: 2)
    let epoch = await store.epoch
    await store.reset(to: 0)
    await store.playerIsAt(CMTime(seconds: 30, preferredTimescale: 1_000), epoch: epoch)
    let far = Self.packet(16)
    let beyond = Task { try await store.append(far) }
    try await Self.pause()
    let holding = await store.isHoldingReading
    XCTAssertTrue(holding, "still two ahead of the start")
    beyond.cancel()
  }

  /// Segments played through without being asked for are let go as well.
  func testSegmentsPlayedFromWhatThePlayerKeptAreLetGo() async throws {
    let store = store(window: 9, keepBehind: 2)
    try await Self.append(0...27, to: store)
    let epoch = await store.epoch
    await store.playerIsAt(CMTime(seconds: 0.7, preferredTimescale: 1_000), epoch: epoch) // segment 5
    await assertGone(store, 2)
    let kept = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(kept), [12, 13, 14, 15])
  }

  func testHeldReadingEndsWhenCancelled() async throws {
    let store = store(window: 0)
    let far = Self.packet(4)
    let held = Task { try await store.append(far) }
    try await Self.pause()
    held.cancel()
    do {
      _ = try await Self.soon { try await held.value; return true }
      XCTFail("cancelled")
    } catch is CancellationError {}
  }

  /// The packet reading waits with was taken from the cache and nothing else
  /// has it: stopping reading must not lose it, or a seek that goes on from
  /// what is held would find a segment short of its first frame.
  func testAPacketReadingWaitsWithIsKeptWhenReadingStops() async throws {
    let store = store(window: 2)
    try await Self.append(0...11, to: store)
    let far = Self.packet(12)
    let held = Task { try await store.append(far) }
    try await Self.pause()
    let holding = await store.isHoldingReading
    XCTAssertTrue(holding)
    held.cancel()
    _ = await held.result
    _ = try await Self.soon { try await store.packets(of: 2) }
    try await Self.append(13...15, to: store)
    let packets = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(packets), [12, 13, 14, 15])
  }

  func testSegmentsLongPlayedAreLetGo() async throws {
    let store = store(window: 9, keepBehind: 2)
    try await Self.append(0...27, to: store) // segments 0 to 6
    _ = try await Self.soon { try await store.packets(of: 5) }
    await assertGone(store, 2)
    let kept = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(kept), [12, 13, 14, 15])
  }

  // ── Going on after a seek ───────────────────────────

  private static func time(ofFrame frame: Int) -> CMTime { packet(frame).presentationTime }

  /// A seek forward into what is read keeps the store as it is, when the
  /// player's first segment is held or still to come, and what reading
  /// brings next follows the last packet taken.
  func testASeekGoesOnFromASegmentHeldOrStillToCome() async throws {
    let store = store(window: 9)
    try await Self.append(0...11, to: store) // segments 0 to 2
    let held = await store.keep(from: 1, nextPacketAt: Self.time(ofFrame: 12))
    XCTAssertTrue(held)
    let ahead = await store.keep(from: 6, nextPacketAt: Self.time(ofFrame: 12))
    XCTAssertTrue(ahead, "not read yet, but it comes in order")
  }

  func testASeekCannotGoOnFromASegmentLetGo() async throws {
    let store = store(window: 9, keepBehind: 2)
    try await Self.append(0...27, to: store)
    _ = try await Self.soon { try await store.packets(of: 5) } // lets go before segment 3
    let gone = await store.keep(from: 2, nextPacketAt: Self.time(ofFrame: 28))
    XCTAssertFalse(gone, "reading will not come back for it")
    let kept = await store.keep(from: 3, nextPacketAt: Self.time(ofFrame: 28))
    XCTAssertTrue(kept)
  }

  /// A packet missing between what the store has and what reading brings next
  /// would leave a hole in a segment.
  func testASeekCannotGoOnWhereAPacketIsMissing() async throws {
    let store = store(window: 9)
    try await Self.append(0...11, to: store)
    let gap = await store.keep(from: 1, nextPacketAt: Self.time(ofFrame: 13))
    XCTAssertFalse(gap, "frame 12 is nowhere")
    let none = await store.keep(from: 1, nextPacketAt: nil)
    XCTAssertFalse(none, "nothing to tell that none was lost")
  }

  func testASeekCannotGoOnBeforeAnythingIsTaken() async {
    let store = store()
    let fresh = await store.keep(from: 0, nextPacketAt: Self.time(ofFrame: 0))
    XCTAssertFalse(fresh)
  }

  /// Reading over, with nothing queued to deliver: the pipeline would not
  /// learn where the sound ends, which only delivering its packets tells it.
  func testASeekCannotGoOnWhenNoPacketIsLeftToDeliver() async throws {
    let store = store(window: 9)
    try await Self.append(0...11, to: store)
    await store.finish()
    let ended = await store.keep(from: 2, nextPacketAt: nil)
    XCTAssertFalse(ended)
  }

  /// Packets that skipped ahead or went back since the last reset — a seek
  /// that was overtaken, a packet dropped on the way — leave a hole or a
  /// doubled frame, whatever follows them.
  func testASeekCannotGoOnAfterPacketsCameOutOfOrder() async throws {
    let skipped = store(window: 9)
    try await Self.append(0...5, to: skipped)
    try await Self.append(8...9, to: skipped)
    let hole = await skipped.keep(from: 1, nextPacketAt: Self.time(ofFrame: 10))
    XCTAssertFalse(hole, "frames 6 and 7 never came")

    let back = store(window: 9)
    try await Self.append(0...7, to: back)
    try await Self.append(2...3, to: back)
    let doubled = await back.keep(from: 1, nextPacketAt: Self.time(ofFrame: 8))
    XCTAssertFalse(doubled)

    await skipped.reset(to: 0)
    try await Self.append(0...5, to: skipped)
    let again = await skipped.keep(from: 0, nextPacketAt: Self.time(ofFrame: 6))
    XCTAssertTrue(again, "starting again clears it")
  }

  /// A seek that goes on hands over again the packet reading was holding,
  /// which may or may not have been taken: the second time changes nothing.
  func testThePacketHandedOverAgainIsTakenOnce() async throws {
    let store = store(window: 9)
    try await Self.append(0...5, to: store)
    try await store.append(Self.packet(5))
    try await Self.append(6...7, to: store)
    let packets = try await Self.soon { try await store.packets(of: 1) }
    XCTAssertEqual(Self.frames(packets), [4, 5, 6, 7])
    let goes = await store.keep(from: 1, nextPacketAt: Self.time(ofFrame: 8))
    XCTAssertTrue(goes, "handing it over again is not packets out of order")
  }

  /// A hand-over cancelled before the packet was taken in did not happen:
  /// handed over again, the packet must go in, not be taken for one already had.
  func testAPacketCancelledBeforeItWentInIsTakenWhenHandedOverAgain() async throws {
    let store = store(window: 9)
    try await Self.append(0...5, to: store)
    let late = Self.packet(6)
    let lost = Task {
      while !Task.isCancelled { await Task.yield() }
      try await store.append(late)
    }
    lost.cancel()
    _ = await lost.result
    try await store.append(late)
    try await store.append(Self.packet(7))
    let packets = try await Self.soon { try await store.packets(of: 1) }
    XCTAssertEqual(Self.frames(packets), [4, 5, 6, 7])
    let goes = await store.keep(from: 1, nextPacketAt: Self.time(ofFrame: 8))
    XCTAssertTrue(goes, "nothing came out of order")
  }

  // ── Not let go before the player gets there ─────────

  /// The first segment a seek going on will have the player ask for must
  /// still be there when it does; requests that were already out, answered
  /// meanwhile, would let it go.
  func testTheFirstSegmentOfASeekIsNotLetGoBeforeThePlayerIsThere() async throws {
    let store = store(window: 9, keepBehind: 2)
    try await Self.append(0...27, to: store) // segments 0 to 6
    let kept = await store.keep(from: 3, nextPacketAt: Self.time(ofFrame: 28))
    XCTAssertTrue(kept)
    _ = try await Self.soon { try await store.packets(of: 6) } // would let go before segment 4
    let held = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(held), [12, 13, 14, 15])
    // Moved, and at the segment holding the target: it is there, and what is behind goes on being let go.
    await store.playerWasMoved()
    let epoch = await store.epoch
    await store.playerIsAt(CMTime(seconds: 0.4, preferredTimescale: 1_000), epoch: epoch) // segment 3
    _ = try await Self.soon { try await store.packets(of: 6) }
    await assertGone(store, 3)
  }

  /// What the player was told to be at before it was moved says nothing of
  /// where it goes: only places told after the move release the segment.
  func testTheSegmentIsOnlyReleasedByWhereThePlayerIsOnceMoved() async throws {
    let store = store(window: 9, keepBehind: 2)
    try await Self.append(0...27, to: store)
    let kept = await store.keep(from: 3, nextPacketAt: Self.time(ofFrame: 28))
    XCTAssertTrue(kept)
    let before = await store.epoch
    let there = CMTime(seconds: 0.4, preferredTimescale: 1_000) // segment 3
    await store.playerIsAt(there, epoch: before) // a look at the old place, taken after the claim
    _ = try await Self.soon { try await store.packets(of: 6) } // would let go before segment 4
    var held = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(held), [12, 13, 14, 15], "not yet moved")
    await store.playerWasMoved()
    await store.playerIsAt(there, epoch: before) // told from before the move
    _ = try await Self.soon { try await store.packets(of: 6) }
    held = try await Self.soon { try await store.packets(of: 3) }
    XCTAssertEqual(Self.frames(held), [12, 13, 14, 15], "void")
    let moved = await store.epoch
    await store.playerIsAt(there, epoch: moved)
    _ = try await Self.soon { try await store.packets(of: 6) }
    await assertGone(store, 3)
  }

  func testStartingAgainLetsGoOfWhatASeekHeld() async throws {
    let store = store(window: 9, keepBehind: 2)
    try await Self.append(0...27, to: store)
    let kept = await store.keep(from: 3, nextPacketAt: Self.time(ofFrame: 28))
    XCTAssertTrue(kept)
    await store.reset(to: 5)
    try await Self.append(20...27, to: store)
    _ = try await Self.soon { try await store.packets(of: 6) } // lets go before segment 4
    await assertGone(store, 4)
  }

  // ── The initialization segment ─────────────────────

  func testTheFirstPacketsComeOnceThereAreEnough() async throws {
    let store = store()
    let leading = Task { try await store.leading() }
    try await Self.append(0...2, to: store)
    try await Self.pause()
    let waiting = await store.isWaiting
    XCTAssertTrue(waiting)
    try await Self.append(3...5, to: store)
    let packets = try await Self.soon { try await leading.value }
    XCTAssertEqual(Self.frames(packets), [0, 1, 2, 3])
  }

  func testAShortTrackGivesWhatItHas() async throws {
    let store = store()
    try await Self.append(0...1, to: store)
    await store.finish()
    let packets = try await Self.soon { try await store.leading() }
    XCTAssertEqual(Self.frames(packets), [0, 1])
  }

  // ── Closing ─────────────────────────────────────────

  func testClosingLetsARequestGo() async throws {
    let store = store()
    let request = Task { try await store.packets(of: 3) }
    try await Self.pause()
    await store.close()
    do {
      _ = try await Self.soon { try await request.value }
      XCTFail("closed")
    } catch SegmentStore.Failure.closed {}
  }

  func testClosingLetsHeldReadingGo() async throws {
    let store = store(window: 0)
    let far = Self.packet(20)
    let held = Task { try await store.append(far) }
    try await Self.pause()
    await store.close()
    do {
      _ = try await Self.soon { try await held.value; return true }
      XCTFail("closed")
    } catch SegmentStore.Failure.closed {}
  }

  private func assertGone(
    _ store: SegmentStore, _ index: Int, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await Self.soon { try await store.packets(of: index) }
      XCTFail("segment \(index) should be gone", file: file, line: line)
    } catch SegmentStore.Failure.gone(let gone) {
      XCTAssertEqual(gone, index, file: file, line: line)
    } catch {
      XCTFail("\(error)", file: file, line: line)
    }
  }
}
