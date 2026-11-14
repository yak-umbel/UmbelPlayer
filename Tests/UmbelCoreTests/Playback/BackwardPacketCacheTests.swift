import CoreMedia
import XCTest
@testable import UmbelCore

final class BackwardPacketCacheTests: XCTestCase {
  private let video = UmbelTrack.ID(rawValue: 0)
  private let audio = UmbelTrack.ID(rawValue: 1)

  private func at(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 90_000)
  }

  private func packet(_ track: UmbelTrack.ID, _ time: Double, bytes: Int = 10,
                      key: Bool = true, duration: Double = 1) -> DemuxPacket {
    DemuxPacket(trackID: track, data: Data(repeating: UInt8(Int(time) % 256), count: bytes),
                presentationTime: at(time), decodeTime: at(time), duration: at(duration), isKeyframe: key)
  }

  private func makeCache(budget: Int = 200) -> PacketCache {
    PacketCache(configuration: .init(target: 60, maximumBackwardPacketBytes: budget),
                measuredTrack: audio, videoTracks: [video])
  }

  private func fill(_ cache: PacketCache, through end: Int = 10) async {
    for t in 0..<end {
      await cache.append(packet(video, Double(t), key: t % 2 == 0))
      await cache.append(packet(audio, Double(t)))
    }
  }

  private func consume(_ cache: PacketCache, count: Int) async {
    for _ in 0..<count {
      _ = await cache.take(from: video, keeping: [video, audio])
      _ = await cache.take(from: audio, keeping: [video, audio])
    }
  }

  func testRewindReplaysInOrderAndJoinsUnreadPacketsWithoutDuplicates() async {
    let cache = makeCache()
    await fill(cache)
    await consume(cache, count: 6)
    let moved = await cache.rewind(to: at(2.5), video: video, audio: audio)
    XCTAssertTrue(moved)
    var pictures: [Double] = []
    var sounds: [Double] = []
    for _ in 0..<8 {
      if let p = await cache.take(from: video, keeping: [video, audio]) { pictures.append(p.presentationTime.seconds) }
      if let p = await cache.take(from: audio, keeping: [video, audio]) { sounds.append(p.presentationTime.seconds) }
    }
    XCTAssertEqual(pictures, [2, 3, 4, 5, 6, 7, 8, 9])
    XCTAssertEqual(sounds, [2, 3, 4, 5, 6, 7, 8, 9])
    let bytes = await cache.backwardPacketBytes
    XCTAssertLessThanOrEqual(bytes, 200)
  }

  func testHistoryDoesNotInflateForwardReadinessAndTransfersWithoutGrowingTotalPayload() async {
    let cache = makeCache()
    await fill(cache)
    await consume(cache, count: 6)
    let duration = await cache.bufferedSeconds
    let forward = await cache.bufferedPacketBytes
    let backward = await cache.backwardPacketBytes
    XCTAssertEqual(duration, 4)
    XCTAssertEqual(forward, 80)
    XCTAssertEqual(backward, 120)
    _ = await cache.rewind(to: at(2.5), video: video, audio: audio)
    let afterForward = await cache.bufferedPacketBytes
    let afterBackward = await cache.backwardPacketBytes
    XCTAssertEqual(afterForward + afterBackward, 200)
    let afterSeconds = await cache.bufferedSeconds
    XCTAssertEqual(afterSeconds, 8)
  }

  func testSharedBudgetEvictsOldestAndOnlyCompleteVideoGroupsCanReplay() async {
    let cache = makeCache(budget: 65)
    await fill(cache)
    await consume(cache, count: 6)
    let bytes = await cache.backwardPacketBytes
    XCTAssertLessThanOrEqual(bytes, 65)
    let old = await cache.rewind(to: at(2.5), video: video, audio: audio)
    XCTAssertFalse(old)
    let recent = await cache.rewind(to: at(4.5), video: video, audio: audio)
    XCTAssertTrue(recent)
    let first = await cache.take(from: video, keeping: [video, audio])
    XCTAssertEqual(first?.presentationTime.seconds, 4)
  }

  func testDisabledAndOversizeHistoryFallBackWithoutChangingQueues() async {
    for budget in [0, -1, 5] {
      let cache = makeCache(budget: budget)
      await fill(cache)
      await consume(cache, count: 6)
      let moved = await cache.rewind(to: at(4.5), video: video, audio: audio)
      XCTAssertFalse(moved)
      let bytes = await cache.backwardPacketBytes
      XCTAssertEqual(bytes, 0)
      let next = await cache.take(from: video, keeping: [video, audio])
      XCTAssertEqual(next?.presentationTime.seconds, 6)
    }
  }

  func testMissingAudioAndVideoGapsRejectAtomically() async {
    for missing in [audio, video] {
      let cache = makeCache()
      for t in 0..<10 {
        if missing != video || t != 3 { await cache.append(packet(video, Double(t), key: t % 2 == 0)) }
        if missing != audio || t != 3 { await cache.append(packet(audio, Double(t))) }
      }
      await consume(cache, count: 5)
      let before = await cache.bufferedPacketBytes
      let moved = await cache.rewind(to: at(2.5), video: video, audio: audio)
      XCTAssertFalse(moved)
      let after = await cache.bufferedPacketBytes
      XCTAssertEqual(after, before)
    }
  }

  func testSoundRequiresItsWarmupBeforeTarget() async {
    let cache = makeCache()
    for t in 0..<10 { await cache.append(packet(audio, Double(t) * 0.1, duration: 0.1)) }
    for _ in 0..<5 { _ = await cache.take(from: audio, keeping: [audio]) }
    let moved = await cache.rewind(to: at(0.45), video: nil, audio: audio)
    XCTAssertTrue(moved)
    let first = await cache.take(from: audio, keeping: [audio])
    XCTAssertEqual(first?.presentationTime.seconds ?? -1, 0.3, accuracy: 0.00001)
  }

  func testForwardSkipRetainsPacketsForASecondSeekBack() async {
    let cache = makeCache()
    await fill(cache)
    let forward = await cache.skipAhead(to: at(6.5), video: video, audio: audio)
    XCTAssertTrue(forward)
    let backward = await cache.rewind(to: at(2.5), video: video, audio: audio)
    XCTAssertTrue(backward)
    let again = await cache.skipAhead(to: at(7.5), video: video, audio: audio)
    XCTAssertTrue(again)
    let backAgain = await cache.rewind(to: at(4.5), video: video, audio: audio)
    XCTAssertTrue(backAgain)
    let next = await cache.take(from: video, keeping: [video, audio])
    XCTAssertEqual(next?.presentationTime.seconds, 4)
    let bytes = await cache.backwardPacketBytes
    XCTAssertLessThanOrEqual(bytes, 200)
  }

  func testFlushAndTrackChangeInvalidateHistory() async {
    let cache = makeCache()
    await cache.select([video, audio], revision: 1)
    await fill(cache)
    await consume(cache, count: 6)
    await cache.select([video], revision: 2)
    let moved = await cache.rewind(to: at(2.5), video: video, audio: nil)
    XCTAssertFalse(moved)
    await cache.flush()
    let bytes = await cache.backwardPacketBytes
    XCTAssertEqual(bytes, 0)
  }

  func testInactiveAudioPrunedBeforeRewindRequiresRereadOnSelection() async {
    let alternate = UmbelTrack.ID(rawValue: 2)
    let cache = makeCache(budget: 2000)
    await cache.select([video, audio], revision: 1)
    await fill(cache, through: 30)
    for t in 0..<30 { await cache.append(packet(alternate, Double(t))) }
    await consume(cache, count: 20)
    let nearPlayhead = await cache.dropped(alternate, after: at(19.5))
    XCTAssertFalse(nearPlayhead, "ordinary switching still has the upcoming audio")
    let beforeRewind = await cache.dropped(alternate, after: at(2.5))
    XCTAssertFalse(beforeRewind, "pruning alone preserves ordinary decode-ahead switching")
    let moved = await cache.rewind(to: at(2.5), video: video, audio: audio)
    XCTAssertTrue(moved)
    await cache.select([video, alternate], revision: 2)
    let lost = await cache.dropped(alternate, after: at(2.5))
    XCTAssertTrue(lost, "the alternate track starts at 19, leaving a gap after the rewind")
    await cache.flush()
    let reset = await cache.dropped(alternate, after: at(2.5))
    XCTAssertFalse(reset)
  }

  func testNewSubtitleRouteCannotUseRequirementsCapturedBeforeSelection() async {
    let subtitle = UmbelTrack.ID(rawValue: 3)
    let cache = PacketCache(
      configuration: .init(target: 60, maximumBackwardPacketBytes: 2000),
      measuredTrack: audio, videoTracks: [video], subtitleTracks: [subtitle])
    await cache.append(packet(subtitle, 1, duration: 3))
    await cache.append(packet(subtitle, 15))
    await fill(cache, through: 30)
    await consume(cache, count: 20)
    _ = await cache.routeSubtitles(to: subtitle)
    let before = await cache.bufferedPacketBytes
    let moved = await cache.rewind(to: at(15.5), video: video, audio: audio,
                                   subtitleRequirements: [:])
    XCTAssertFalse(moved, "missing requirements cannot stand in for a bitmap decoder's dependencies")
    let after = await cache.bufferedPacketBytes
    XCTAssertEqual(after, before, "a stale route must be rejected before moving any packets")
  }

  func testSelectedSubtitleHistoryIsRequeuedAndMissingCuesForceReread() async {
    let subtitle = UmbelTrack.ID(rawValue: 3)
    let cache = PacketCache(
      configuration: .init(target: 60, maximumBackwardPacketBytes: 1000),
      measuredTrack: audio, videoTracks: [video], subtitleTracks: [subtitle])
    _ = await cache.routeSubtitles(to: subtitle)
    await cache.append(packet(subtitle, 1, duration: 2))
    await fill(cache, through: 20)
    _ = await cache.take(from: subtitle, upTo: at(4))
    await consume(cache, count: 6)
    let requirements = [subtitle: SubtitleReplayRequirement(time: at(2.5))]
    let moved = await cache.rewind(to: at(2.5), video: video, audio: audio,
                                   subtitleRequirements: requirements)
    XCTAssertTrue(moved)
    let cues = await cache.take(from: subtitle, upTo: at(2.5))
    XCTAssertEqual(cues.map(\.presentationTime.seconds), [1])
    await consume(cache, count: 14)
    let missing = await cache.rewind(to: at(2.5), video: video, audio: audio,
                                     subtitleRequirements: requirements)
    XCTAssertFalse(missing, "the subtitle ended at 3 and has since been evicted")
  }

  func testRewindAtForwardByteLimitTransfersPayloadAndPausesReadingUntilDrained() async {
    let cache = PacketCache(configuration: .init(target: 60, maximumPacketBytes: 60,
                                                maximumBackwardPacketBytes: 100),
                            measuredTrack: audio, videoTracks: [video])
    await fill(cache, through: 3)
    await consume(cache, count: 2)
    for t in 3..<5 {
      await cache.append(packet(video, Double(t), key: t % 2 == 0))
      await cache.append(packet(audio, Double(t)))
    }
    let moved = await cache.rewind(to: at(0.5), video: video, audio: audio)
    XCTAssertTrue(moved)
    let forward = await cache.bufferedPacketBytes
    let backward = await cache.backwardPacketBytes
    XCTAssertEqual(forward + backward, 100)
    let blocked = await cache.prepareToRead()
    XCTAssertFalse(blocked)
    await consume(cache, count: 3)
    let ready = await cache.prepareToRead()
    XCTAssertTrue(ready)
  }

  func testReorderedPresentationTimesReplayInDecodeOrder() async {
    let cache = makeCache()
    for (dts, pts) in [0.0, 3, 1, 2, 4, 7, 5, 6].enumerated() {
      await cache.append(DemuxPacket(trackID: video, data: Data(count: 10),
                                    presentationTime: at(pts), decodeTime: at(Double(dts)),
                                    duration: at(1), isKeyframe: dts % 4 == 0))
    }
    for _ in 0..<5 { _ = await cache.take(from: video, keeping: [video]) }
    let moved = await cache.rewind(to: at(1.5), video: video, audio: nil)
    XCTAssertTrue(moved)
    var times: [Double] = []
    for _ in 0..<8 {
      if let packet = await cache.take(from: video, keeping: [video]) { times.append(packet.presentationTime.seconds) }
    }
    XCTAssertEqual(times, [0, 3, 1, 2, 4, 7, 5, 6])
  }

  func testOversizePacketBreaksHistoryUntilNextKeyframe() async {
    let cache = makeCache(budget: 100)
    for t in 0..<8 {
      await cache.append(packet(video, Double(t), bytes: t == 3 ? 101 : 10, key: t % 2 == 0))
    }
    for _ in 0..<6 { _ = await cache.take(from: video, keeping: [video]) }
    let broken = await cache.rewind(to: at(2.5), video: video, audio: nil)
    XCTAssertFalse(broken)
    let recovered = await cache.rewind(to: at(4.5), video: video, audio: nil)
    XCTAssertTrue(recovered)
  }

  func testCoarseTimestampsCannotHideAMissingOrRepeatedFrame() {
    func frame(_ tick: Int64) -> DemuxPacket {
      DemuxPacket(trackID: video, data: Data(count: 10),
                  presentationTime: CMTime(value: tick, timescale: 25),
                  decodeTime: CMTime(value: tick, timescale: 25),
                  duration: CMTime(value: 1, timescale: 25), isKeyframe: tick == 0)
    }
    XCTAssertTrue(BackwardPacketHistory.follows(frame(1), after: frame(0)))
    XCTAssertFalse(BackwardPacketHistory.follows(frame(2), after: frame(0)))
    XCTAssertFalse(BackwardPacketHistory.follows(frame(0), after: frame(0)))
  }

  func testStatefulSubtitleReplayRequiresEveryEarlierPacketEvenAfterItsDisplayEnds() {
    let subtitle = UmbelTrack.ID(rawValue: 3)
    var history = SubtitleHistory()
    history.remember(packet(subtitle, 0, duration: 1))
    history.remember(packet(subtitle, 3, duration: 1))
    XCTAssertTrue(history.canReplay(subtitle, at: 3.5, requiresCompleteHistory: true))
    history.forget(before: 12)
    XCTAssertTrue(history.canReplay(subtitle, at: 3.5))
    XCTAssertFalse(history.canReplay(subtitle, at: 3.5, requiresCompleteHistory: true),
                   "the expired display could define a palette used by the later display")
    let replay = history.takeForReplay(subtitle)
    for packet in replay { history.remember(packet) }
    XCTAssertFalse(history.canReplay(subtitle, at: 3.5, requiresCompleteHistory: true))
    history.removeAll()
    XCTAssertTrue(history.canReplay(subtitle, at: 3.5, requiresCompleteHistory: true))
  }

  func testLongRunningEvictionKeepsLatestPacketsAndReleasesAccounting() {
    var history = BackwardPacketHistory(maximumBytes: 20_000, videoTracks: [])
    for t in 0..<10_000 {
      history.append((packet(audio, Double(t)), 1))
      XCTAssertLessThanOrEqual(history.bytes, 20_000)
    }
    let retained = history.entries(for: audio)
    XCTAssertEqual(retained.count, 2000)
    XCTAssertEqual(retained.first?.packet.presentationTime.seconds, 8000)
    XCTAssertEqual(retained.last?.packet.presentationTime.seconds, 9999)
    history.remove(audio)
    XCTAssertEqual(history.bytes, 0)
    XCTAssertTrue(history.entries(for: audio).isEmpty)
  }
}
