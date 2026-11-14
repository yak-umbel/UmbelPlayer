import XCTest
@testable import UmbelCore

/// Time that passes only when slept through, or when a test says so.
private final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time = 0.0
  private var slept: [Double] = []

  var sleeps: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return slept
  }

  func advance(_ seconds: Double) {
    lock.lock()
    time += seconds
    lock.unlock()
  }

  private func sleep(_ seconds: Double) {
    lock.lock()
    time += seconds
    slept.append(seconds)
    lock.unlock()
  }

  private func read() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return time
  }

  var clock: HLSLivePlaylist.Clock {
    HLSLivePlaylist.Clock(
      now: { [self] in read() },
      sleep: { [self] seconds in sleep(seconds) })
  }
}

/// What each reload of the playlist gets, in turn; the last again after.
private final class Reloads: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Result<HLSMediaPlaylist, Error>]
  private var made = 0

  init(_ answers: [Result<HLSMediaPlaylist, Error>]) { self.answers = answers }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return made
  }

  func next() throws -> HLSMediaPlaylist {
    lock.lock()
    let answer = answers[min(made, answers.count - 1)]
    made += 1
    lock.unlock()
    return try answer.get()
  }
}

final class HLSLivePlaylistTests: XCTestCase {
  private let base = URL(string: "https://live.invalid/channel/index.m3u8")!

  /// Two-second segments `s<sequence>.ts`, the ones in `sequences`.
  private func window(
    _ sequences: ClosedRange<Int>, ended: Bool = false, breakBefore: Int? = nil
  ) throws -> HLSMediaPlaylist {
    var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(sequences.lowerBound)"]
    for sequence in sequences {
      if sequence == breakBefore { lines.append("#EXT-X-DISCONTINUITY") }
      lines += ["#EXTINF:2,", "s\(sequence).ts"]
    }
    if ended { lines.append("#EXT-X-ENDLIST") }
    return try HLSMediaPlaylist.parse(lines.joined(separator: "\n"), base: base)
  }

  private func live(
    _ first: HLSMediaPlaylist, _ reloads: Reloads, _ clock: FakeClock = FakeClock()
  ) -> HLSLivePlaylist {
    HLSLivePlaylist(first: first, reload: { try reloads.next() }, clock: clock.clock)
  }

  private func sequences(_ live: HLSLivePlaylist, _ indices: Range<Int>) async throws -> [Int?] {
    var found: [Int?] = []
    for index in indices { found.append(try await live.segment(at: index)?.sequence) }
    return found
  }

  /// Three target durations back from the newest: close enough to the edge
  /// to be live, far enough to ride out a slow reload.
  func testStartsThreeTargetDurationsFromTheEdge() async throws {
    let live = live(try window(0...5), Reloads([]))
    let first = try await live.segment(at: 0)
    XCTAssertEqual(first?.sequence, 3)
    XCTAssertEqual(first?.start, 0, "the timeline starts where watching does")
    let second = try await live.segment(at: 1)
    XCTAssertEqual(second?.start, 2)
  }

  /// Reloads overlap the segments already known: each is joined once, in
  /// order, its start following on.
  func testNewSegmentsAreJoinedBySequence() async throws {
    let reloads = Reloads([.success(try window(2...7)), .success(try window(4...9))])
    let live = live(try window(0...5), reloads)
    // Asked for in order, each once, as playing asks: one played is gone
    // from the server by the time the list has moved past it.
    var found: [HLSMediaPlaylist.Segment] = []
    for index in 0..<7 {
      let segment = try await live.segment(at: index)
      found.append(try XCTUnwrap(segment))
    }
    XCTAssertEqual(found.map(\.sequence), [3, 4, 5, 6, 7, 8, 9])
    XCTAssertEqual(found.map(\.start), [0, 2, 4, 6, 8, 10, 12])
    let runs = Set(found.map(\.run))
    XCTAssertEqual(runs.count, 1)
    XCTAssertEqual(reloads.count, 2)
  }

  /// A discontinuity in a reload starts a run, as it does in a fixed list;
  /// so does a gap in the sequence — whatever was missed may have been one.
  func testBreaksAndGapsStartRuns() async throws {
    let reloads = Reloads([
      .success(try window(4...7, breakBefore: 7)), .success(try window(20...23)),
    ])
    let live = live(try window(0...5), reloads)
    var runs: [Int] = []
    for index in 0..<6 { runs.append(try await live.segment(at: index)?.run ?? -1) }
    // 3 4 5 6 | 7 | 20 …
    XCTAssertEqual(runs[0], runs[3])
    XCTAssertNotEqual(runs[3], runs[4])
    XCTAssertNotEqual(runs[4], runs[5])
    let jumped = try await live.segment(at: 5)
    XCTAssertEqual(jumped?.sequence, 20)
  }

  func testAnEndedLiveListEnds() async throws {
    let reloads = Reloads([.success(try window(4...7, ended: true))])
    let live = live(try window(0...5), reloads)
    let found = try await sequences(live, 0..<6)
    XCTAssertEqual(found, [3, 4, 5, 6, 7, nil])
    XCTAssertEqual(reloads.count, 1, "no reloads once it has ended")
  }

  /// Held up so long the next segment has gone from the server: on from the
  /// oldest one still there, as a new run.
  func testFallingOutOfTheWindowJumpsToItsStart() async throws {
    let clock = FakeClock()
    let reloads = Reloads([.success(try window(20...25))])
    let live = live(try window(0...5), reloads, clock)
    let before = try await live.segment(at: 0)
    XCTAssertEqual(before?.sequence, 3)
    clock.advance(30)
    let after = try await live.segment(at: 0)
    XCTAssertEqual(after?.sequence, 20)
    XCTAssertEqual(after?.start, 0)
    XCTAssertNotEqual(after?.run, before?.run)
    let next = try await live.segment(at: 1)
    XCTAssertEqual(next?.sequence, 21)
    XCTAssertEqual(next?.run, after?.run)
  }

  /// A reload that brought something waits a target duration for the next;
  /// one that brought nothing, half of one.
  func testReloadsWaitATargetDurationOrHalfOne() async throws {
    let clock = FakeClock()
    let reloads = Reloads([.success(try window(0...5)), .success(try window(1...6))])
    let live = live(try window(0...5), reloads, clock)
    let found = try await live.segment(at: 3)
    XCTAssertEqual(found?.sequence, 6)
    XCTAssertEqual(clock.sleeps, [2, 1])
  }

  func testReloadFailuresGiveUpAfterThree() async throws {
    let reloads = Reloads([.failure(URLError(.timedOut))])
    let live = live(try window(0...5), reloads)
    do {
      _ = try await live.segment(at: 3)
      XCTFail("three failed reloads in a row end it")
    } catch {}
    XCTAssertEqual(reloads.count, 3)
    do {
      _ = try await live.segment(at: 3)
      XCTFail("and it stays ended")
    } catch {}
    XCTAssertEqual(reloads.count, 3)
  }

  func testReloadFailuresThatRecoverAreForgotten() async throws {
    let reloads = Reloads([
      .failure(URLError(.timedOut)), .failure(URLError(.timedOut)), .success(try window(2...7)),
      .failure(URLError(.timedOut)), .failure(URLError(.timedOut)), .success(try window(4...9)),
    ])
    let live = live(try window(0...5), reloads)
    let found = try await sequences(live, 3..<7)
    XCTAssertEqual(found, [6, 7, 8, 9])
  }

  /// Stopping does not wait out a reload's wait.
  func testCancellingEndsAWait() async throws {
    let reloads = Reloads([.success(try window(0...5))])
    let live = HLSLivePlaylist(
      first: try window(0...5), reload: { try reloads.next() },
      clock: HLSLivePlaylist.Clock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 30 * 1_000_000_000)) }))
    let waiting = Task { try await live.segment(at: 3) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let started = Date()
    await live.cancel()
    _ = try? await waiting.value
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }
}
