import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore
import UmbelFFmpegSupport

/// A server that cannot listen, as in a sandboxed Mac app without the
/// incoming connections entitlement.
struct RefusingServer: LoopbackServing {
  func register(_ handler: @escaping LoopbackServer.Handler) async throws -> URL {
    throw POSIXError(.EPERM)
  }
  func unregister(_ base: URL) async {}
}

/// The real server, with the route's handler kept to ask it directly what it would serve.
private final class SpyServer: LoopbackServing, @unchecked Sendable {
  private let lock = NSLock()
  private var registered: LoopbackServer.Handler?

  var handler: LoopbackServer.Handler? { lock.withLock { registered } }

  func register(_ handler: @escaping LoopbackServer.Handler) async throws -> URL {
    lock.withLock { registered = handler }
    return try await LoopbackServer.shared.register(handler)
  }

  func unregister(_ base: URL) async { await LoopbackServer.shared.unregister(base) }
}

/// Counts what it is asked.
private actor Counter {
  private(set) var count = 0
  func add() { count += 1 }
}

/// Collects what a route reports.
private actor Reports {
  private(set) var reasons: [UmbelObjectAudioFallback] = []
  func add(_ reason: UmbelObjectAudioFallback) { reasons.append(reason) }
}

/// A sound track taken by reading and played by the system player. The
/// fixture's E-AC-3 has no object coding; the tests route it regardless.
final class ObjectAudioRouteTests: XCTestCase {
  private struct Fixture: @unchecked Sendable {
    let track: UmbelTrack
    let parameters: FFmpegCodecParameters
    let duration: CMTime
    let packets: [DemuxPacket]
  }

  private static func fixture() async throws -> Fixture {
    let demux = DemuxSession(source: try UmbelFileSource(url: ServedEAC3.fixture("eac3_movie.mkv")))
    try await demux.open()
    let tracks = await demux.tracks
    let sound = try XCTUnwrap(tracks.first { $0.kind == .audio })
    var packets: [DemuxPacket] = []
    while let packet = try await demux.nextPacket() {
      if packet.trackID == sound.id { packets.append(packet) }
    }
    let found = await demux.codecParameters(for: sound.id)
    let parameters = try XCTUnwrap(found)
    let duration = await demux.duration
    await demux.close()
    return Fixture(track: sound, parameters: parameters, duration: duration, packets: packets)
  }

  private func route(
    _ fixture: Fixture, server: any LoopbackServing = LoopbackServer.shared, reports: Reports = Reports()
  ) -> ObjectAudioRoute {
    let route = ObjectAudioRoute(
      track: fixture.track, parameters: fixture.parameters, duration: fixture.duration,
      server: server, onFailure: { await reports.add($0) })
    addTeardownBlock { await route.close() }
    return route
  }

  /// Reading's part: hands over packets from `start` on, as a demuxer would.
  private static func feed(_ packets: [DemuxPacket], to route: ObjectAudioRoute, from start: CMTime = .zero) -> Task<Void, Error> {
    Task {
      for packet in packets where packet.presentationTime + CMTime(value: 1, timescale: 10) >= start {
        try await route.take(packet)
      }
      await route.finishReading()
    }
  }

  #if targetEnvironment(simulator)
  private static let onSimulator = true
  #else
  private static let onSimulator = false
  #endif

  func testOnlyObjectCodedEAC3OfAKnownLengthGoesThisWay() async throws {
    let fixture = try await Self.fixture()
    XCTAssertFalse(
      ObjectAudioRoute.suits(fixture.track, parameters: fixture.parameters, duration: fixture.duration),
      "the encoder here writes no objects")
    XCTAssertEqual(ObjectAudioRoute.objectCodingProfile, 30)
  }

  func testTheSystemPlayerPlaysWhatReadingHandsOver() async throws {
    let fixture = try await Self.fixture()
    let route = route(fixture)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    let feeding = Self.feed(fixture.packets, to: route)
    addTeardownBlock { feeding.cancel() }
    let lead = await route.takeLead()
    let timeline = try XCTUnwrap(lead)
    timeline.set(rate: 1, time: .zero)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    XCTAssertEqual(timeline.player.volume, 0)
    // Its clock can start a moment after it says it plays: until then it
    // stands where it was, and then runs on from where the sound begins, a
    // tenth of a second back. Read before, it would be a tenth short.
    let standing = timeline.time
    for _ in 0..<150 where timeline.time == standing {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let start = timeline.time.seconds
    let elapsed = try await sleepMeasured(0.5)
    XCTAssertEqual(timeline.time.seconds - start, elapsed, accuracy: 0.15, "the player's clock runs")
    let stalled = await route.isWaitingToPlay
    XCTAssertFalse(stalled)
  }

  /// Before its clock leads, a seek makes a new player that starts there:
  /// the first one would still want segments reading will not bring.
  func testASeekBeforeLeadingStartsANewPlayerThere() async throws {
    let fixture = try await Self.fixture()
    let route = route(fixture)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    let first = await route.timeline
    let target = CMTime(seconds: 7, preferredTimescale: 600)
    let from = route.readingStart(forSeekTo: target)
    XCTAssertEqual(from.seconds, 4.0, accuracy: 0.001, "segment 2 of 2.016 s, before 7 s's, a 32 ms frame early")
    await route.prepareSeek(to: target)
    let second = await route.timeline
    XCTAssertFalse(first === second)
    let feeding = Self.feed(fixture.packets, to: route, from: from)
    addTeardownBlock { feeding.cancel() }
    let lead = await route.takeLead()
    let timeline = try XCTUnwrap(lead)
    XCTAssertEqual(timeline.player.volume, 0, "the level goes to the new one")
    timeline.set(rate: 1, time: target)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    XCTAssertEqual(timeline.time.seconds, 7, accuracy: 0.3)
  }

  /// Once it leads, a seek moves it: the pictures follow its clock.
  func testASeekWhileLeadingMovesThePlayer() async throws {
    let fixture = try await Self.fixture()
    let route = route(fixture)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    var feeding = Self.feed(fixture.packets, to: route)
    let lead = await route.takeLead()
    let timeline = try XCTUnwrap(lead)
    timeline.set(rate: 1, time: .zero)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    feeding.cancel()
    let target = CMTime(seconds: 9, preferredTimescale: 600)
    await route.prepareSeek(to: target)
    let same = await route.timeline
    XCTAssertTrue(same === timeline)
    feeding = Self.feed(fixture.packets, to: route, from: route.readingStart(forSeekTo: target))
    addTeardownBlock { feeding.cancel() }
    for _ in 0..<60 where abs(timeline.time.seconds - 9) > 0.3 || timeline.player.timeControlStatus != .playing {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(timeline.time.seconds, 9, accuracy: 0.3)
    XCTAssertEqual(timeline.player.timeControlStatus, .playing)
  }

  /// Fails rather than hangs when `operation` does not finish soon.
  private static func soon<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await Task.sleep(nanoseconds: 3_000_000_000)
        return nil
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() ?? nil else { throw NSError(domain: "UmbelPlaybackTest", code: 2) }
      return value
    }
  }

  /// Reading has taken the sound up to 4.1 s; the next packet it brings
  /// starts where this says.
  private static func feedFirstSeconds(_ fixture: Fixture, to route: ObjectAudioRoute) async throws -> CMTime? {
    for packet in fixture.packets where packet.presentationTime.seconds < 4.1 {
      try await route.take(packet)
    }
    return fixture.packets.first { $0.presentationTime.seconds >= 4.1 }?.presentationTime
  }

  /// Before its clock leads, a seek makes a new player: going on with what
  /// is read would leave that one without the segments it is made to ask for.
  func testASeekCannotGoOnWithWhatIsReadBeforeThePlayerLeads() async throws {
    let fixture = try await Self.fixture()
    let route = route(fixture)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    let next = try await Self.feedFirstSeconds(fixture, to: route)
    let target = CMTime(seconds: 2.5, preferredTimescale: 600)
    let early = await route.keepReading(forSeekTo: target, nextPacketAt: next)
    XCTAssertFalse(early)
    let lead = await route.takeLead()
    XCTAssertNotNil(lead)
    let leading = await route.keepReading(forSeekTo: target, nextPacketAt: next)
    XCTAssertTrue(leading, "its segments are held and the next packet follows the last")
  }

  /// Going on with what is read, the player is moved and nothing is
  /// forgotten: the segments it will ask for are still served, though reading
  /// does not bring them again. Starting again forgets those before the
  /// seek's first segment.
  func testASeekThatGoesOnMovesThePlayerAndForgetsNothing() async throws {
    for keeping in [true, false] {
      let fixture = try await Self.fixture()
      let server = SpyServer()
      let route = route(fixture, server: server)
      try await route.start()
      await route.setLevel(volume: 0, muted: true)
      let next = try await Self.feedFirstSeconds(fixture, to: route)
      let lead = await route.takeLead()
      let timeline = try XCTUnwrap(lead)
      let target = CMTime(seconds: 4.5, preferredTimescale: 600) // asks for segment 1 first
      let goes = await route.keepReading(forSeekTo: target, nextPacketAt: next)
      XCTAssertTrue(goes)
      await route.prepareSeek(to: target, keeping: keeping)
      let same = await route.timeline
      XCTAssertTrue(same === timeline, "moved, not replaced")
      XCTAssertEqual(timeline.time.seconds, 4.5, accuracy: 0.001)
      let handler = try XCTUnwrap(server.handler)
      let first = try await Self.soon { try await handler("seg0.m4s") }
      XCTAssertEqual(first != nil, keeping, keeping ? "still held" : "let go: reading will not come back")
      // Started again, segment 1 waits for reading to bring it.
      if keeping {
        let asked = try await Self.soon { try await handler("seg1.m4s") }
        XCTAssertNotNil(asked)
      }
      await route.close()
    }
  }

  func testPacketPressureFallsBackAfterAPlayingRouteSeeksToUnreadSound() async throws {
    let fixture = try await Self.fixture()
    let reports = Reports()
    let route = route(fixture, reports: reports)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    let feeding = Task {
      for packet in fixture.packets where packet.presentationTime.seconds < 4.1 {
        try await route.take(packet)
      }
    }
    addTeardownBlock { feeding.cancel() }
    let lead = await route.takeLead()
    let timeline = try XCTUnwrap(lead)
    timeline.set(rate: 1, time: .zero)
    try await ServedEAC3.waitUntilPlaying(timeline.player)
    await route.fallBackAtPacketLimit(stillWanted: { true })
    let healthy = await reports.reasons
    XCTAssertTrue(healthy.isEmpty, "healthy playback does not fall back for an ordinary full cache")

    await route.prepareSeek(to: CMTime(seconds: 9, preferredTimescale: 600))
    for _ in 0..<200 {
      if await route.isWaitingToPlay { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    for _ in 0..<200 {
      await route.fallBackAtPacketLimit(stillWanted: { true })
      if !(await reports.reasons.isEmpty) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let reasons = await reports.reasons
    XCTAssertEqual(reasons, [.notPlaying], "an already-leading timeline must escape a bounded read deadlock")
  }

  /// A player still getting ready, given every segment it asked for, is
  /// loading, not stuck: at the packet budget it keeps its route, and the
  /// watch sees to one that never gets ready.
  func testALoadingPlayerGivenWhatItAskedForKeepsItsRouteAtThePacketLimit() async throws {
    let fixture = try await Self.fixture()
    let reports = Reports()
    let route = route(fixture, reports: reports)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    for packet in fixture.packets where packet.presentationTime.seconds < 4.1 {
      try await route.take(packet)
    }
    await route.finishReading()
    // Across the player's getting ready.
    for _ in 0..<50 {
      let stuck = await route.isStuckAtPacketLimit
      XCTAssertFalse(stuck)
      await route.fallBackAtPacketLimit(stillWanted: { true })
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let reasons = await reports.reasons
    XCTAssertTrue(reasons.isEmpty, "a player waiting on nothing from reading is not stuck")
  }

  /// A player getting ready that waits on reading, when reading has stopped
  /// at the packet budget, never gets what it waits for.
  func testALoadingPlayerWaitingOnReadingFallsBackAtThePacketLimit() async throws {
    let fixture = try await Self.fixture()
    let reports = Reports()
    let route = route(fixture, reports: reports)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    // Nothing read: the player waits for its first packets.
    for _ in 0..<300 {
      await route.fallBackAtPacketLimit(stillWanted: { true })
      if !(await reports.reasons.isEmpty) { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let reasons = await reports.reasons
    XCTAssertEqual(reasons, [.notPlaying])
  }

  /// The request can go stale while the player is looked at — a seek, a
  /// new route — and is asked about once more after looking: no longer
  /// wanted, it reports nothing.
  func testAPacketLimitRequestNoLongerWantedAfterLookingReportsNothing() async throws {
    let fixture = try await Self.fixture()
    let reports = Reports()
    let route = route(fixture, reports: reports)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    let asked = Counter()
    // Nothing read: the player waits for its first packets, and is stuck.
    for _ in 0..<300 {
      await route.fallBackAtPacketLimit(stillWanted: { await asked.add(); return false })
      if await asked.count > 0 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let count = await asked.count
    XCTAssertGreaterThan(count, 0, "precondition: stuck, and asked whether still wanted")
    let stale = await reports.reasons
    XCTAssertTrue(stale.isEmpty, "a request gone stale while looking reports nothing")
    let reported = await route.fallBackAtPacketLimit(stillWanted: { true })
    let reasons = await reports.reasons
    XCTAssertTrue(reported)
    XCTAssertEqual(reasons, [.notPlaying])
  }

  /// Feeding can still hold a route that fell back; what it hands over then
  /// goes nowhere, and is no failure of playback.
  func testAClosedRouteTakesPacketsWithoutComplaint() async throws {
    let fixture = try await Self.fixture()
    let route = route(fixture)
    try await route.start()
    await route.close()
    for packet in fixture.packets.prefix(300) { try await route.take(packet) }
  }

  func testAServerThatCannotListenIsReportedAtOnce() async throws {
    let fixture = try await Self.fixture()
    let route = route(fixture, server: RefusingServer())
    do {
      try await route.start()
      XCTFail("nothing to serve from")
    } catch let reason as UmbelObjectAudioFallback {
      guard case .serverUnavailable = reason else { return XCTFail("\(reason)") }
    }
  }

  /// Packets that are not E-AC-3 cannot be played.
  func testAPlayerThatCannotPlayIsReported() async throws {
    try XCTSkipIf(Self.onSimulator, "the simulator's player plays what it cannot decode as silence, its clock running")
    try XCTSkipIf(
      HostEnvironment.isVirtualMachine,
      "a virtual machine's player reports nothing for what it cannot decode, as hardware's does")
    let fixture = try await Self.fixture()
    let reports = Reports()
    let route = route(fixture, reports: reports)
    try await route.start()
    await route.setLevel(volume: 0, muted: true)
    let junk = fixture.packets.map {
      DemuxPacket(
        trackID: $0.trackID, data: Data(repeating: 0x5A, count: $0.data.count),
        presentationTime: $0.presentationTime, decodeTime: $0.decodeTime,
        duration: $0.duration, isKeyframe: true)
    }
    let feeding = Self.feed(junk, to: route)
    addTeardownBlock { feeding.cancel() }
    // Taking the lead must not hold the test: a player that never gets
    // ready is for the route to report too.
    let lead = Task { await route.takeLead()?.set(rate: 1, time: .zero) }
    addTeardownBlock { lead.cancel() }
    for _ in 0..<200 where await reports.reasons.isEmpty {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let reasons = await reports.reasons
    // It lets its rate fall to 0, or stays unready, without an error.
    XCTAssertEqual(reasons, [.notPlaying])
  }
}
