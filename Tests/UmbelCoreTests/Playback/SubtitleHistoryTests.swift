import CoreMedia
import XCTest
@testable import UmbelCore

/// The cache keeps the last ten seconds of every subtitle track that has
/// left it, and older lines still showing, for a receiver routed mid-play;
/// the feed hands that over first.
final class SubtitleHistoryTests: XCTestCase {
  private let audio = UmbelTrack.ID(rawValue: 1)
  private let english = UmbelTrack.ID(rawValue: 3)
  private let french = UmbelTrack.ID(rawValue: 4)

  private func packet(_ track: UmbelTrack.ID, at seconds: Double) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: 16),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 600),
      duration: CMTime(seconds: 0.1, preferredTimescale: 600), isKeyframe: true)
  }

  private func times(_ packets: [DemuxPacket]) -> [Double] {
    packets.map(\.presentationTime.seconds)
  }

  private func makeCache() -> PacketCache {
    PacketCache(configuration: .init(), measuredTrack: audio, subtitleTracks: [english, french])
  }

  /// Audio from 0 to `seconds`, a line on each subtitle track every second.
  private func fill(_ cache: PacketCache, to seconds: Int) async {
    for second in 0..<seconds {
      await cache.append(packet(english, at: Double(second)))
      await cache.append(packet(french, at: Double(second) + 0.5))
      for tenth in 0..<10 { await cache.append(packet(audio, at: Double(second) + Double(tenth) / 10)) }
    }
  }

  private func takeAudio(_ cache: PacketCache, keeping kept: Set<UmbelTrack.ID>, to seconds: Double)
    async
  {
    while let next = await cache.take(from: audio, keeping: kept),
      next.presentationTime.seconds < seconds
    {}
  }

  func testPrunedLinesAreKeptForTenSeconds() async {
    let cache = makeCache()
    await fill(cache, to: 20)
    await takeAudio(cache, keeping: [audio], to: 15)
    let english = await cache.routeSubtitles(to: english)
    XCTAssertEqual(times(english), [5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
  }

  private func line(_ track: UmbelTrack.ID, at seconds: Double, lasting duration: Double?) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: 16),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 600),
      duration: duration.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .invalid,
      isKeyframe: true)
  }

  private func feedAudio(_ cache: PacketCache, to seconds: Int) async {
    for tenth in 0..<(seconds * 10) { await cache.append(packet(audio, at: Double(tenth) / 10)) }
  }

  /// A line that began long ago but still shows belongs to the picture now:
  /// a track switched back to would otherwise show nothing until its next line.
  func testALineStillShowingIsKeptBeyondTenSeconds() async {
    let cache = makeCache()
    await cache.append(line(english, at: 0, lasting: 120))
    await cache.append(line(english, at: 1, lasting: 2))
    await feedAudio(cache, to: 25)
    await takeAudio(cache, keeping: [audio], to: 22)
    let english = await cache.routeSubtitles(to: english)
    XCTAssertEqual(times(english), [0], "the long line shows until 120; the short one ended at 3")
  }

  /// A line without an end holds until the next one replaces it — how
  /// picture subtitles show — so the latest of those is kept, not those before.
  func testTheLatestOpenEndedEventIsKept() async {
    let cache = makeCache()
    await cache.append(line(english, at: 0, lasting: nil))
    await cache.append(line(english, at: 2, lasting: nil))
    await cache.append(line(english, at: 2, lasting: nil))
    await feedAudio(cache, to: 25)
    await takeAudio(cache, keeping: [audio], to: 22)
    let english = await cache.routeSubtitles(to: english)
    XCTAssertEqual(times(english), [2, 2], "every packet of the event still in force")
  }

  /// Stated lengths are not trusted to grow the history without end.
  func testLongLinesKeptAreBounded() async {
    let cache = makeCache()
    for second in 0..<200 { await cache.append(line(english, at: Double(second) / 10, lasting: 3_600)) }
    await feedAudio(cache, to: 40)
    await takeAudio(cache, keeping: [audio], to: 35)
    let english = await cache.routeSubtitles(to: english)
    XCTAssertEqual(english.count, SubtitleHistory.lineLimit)
    XCTAssertEqual(english.last?.presentationTime.seconds ?? 0, 19.9, accuracy: 0.001, "the newest are kept")
  }

  func testLinesTakenByADecoderAreKeptToo() async {
    let cache = makeCache()
    await fill(cache, to: 5)
    _ = await cache.routeSubtitles(to: english)
    await takeAudio(cache, keeping: [audio, english], to: 3)
    let taken = await cache.take(from: english, upTo: CMTime(seconds: 3, preferredTimescale: 600))
    XCTAssertEqual(times(taken), [0, 1, 2, 3])
    let back = await cache.routeSubtitles(to: english)
    XCTAssertEqual(times(back), [0, 1, 2, 3], "switching back to a track shown before")
  }

  func testOnlySubtitleTracksAreKept() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio, subtitleTracks: [english])
    await fill(cache, to: 5)
    await takeAudio(cache, keeping: [audio], to: 3)
    let french = await cache.routeSubtitles(to: french)
    XCTAssertEqual(times(french), [])
  }

  func testASeekForgetsThePast() async {
    let cache = makeCache()
    await fill(cache, to: 5)
    await takeAudio(cache, keeping: [audio], to: 3)
    await cache.flush()
    let english = await cache.routeSubtitles(to: english)
    XCTAssertEqual(times(english), [], "that past belongs to another part of the stream")
  }

  /// A chain may still hold the selection from before the switch: what it
  /// prunes then would leave the queue after the past was handed over, and
  /// reach neither the receiver nor its past.
  func testTheRoutedTrackIsSparedFromAStaleSelection() async {
    let cache = makeCache()
    await fill(cache, to: 5)
    _ = await cache.routeSubtitles(to: english)
    await takeAudio(cache, keeping: [audio], to: 3)
    let due = await cache.take(from: english, upTo: CMTime(seconds: 3, preferredTimescale: 600))
    XCTAssertEqual(times(due), [0, 1, 2, 3])
  }
}

/// Holds each packet until let go, so a test can act while the feed is in
/// the middle of handing a track's past over.
private actor GatedReceiver: SubtitlePacketReceiver {
  private(set) var received: [Double] = []
  private var held: [CheckedContinuation<Void, Never>] = []
  private var gated = true

  func receive(_ packet: DemuxPacket) async {
    if gated { await withCheckedContinuation { held.append($0) } }
    received.append(packet.presentationTime.seconds)
  }

  /// Packets waiting at the gate.
  var waiting: Int { held.count }

  func open() {
    gated = false
    for continuation in held { continuation.resume() }
    held = []
  }
}

final class SubtitleFeedTests: XCTestCase {
  private let audio = UmbelTrack.ID(rawValue: 1)
  private let english = UmbelTrack.ID(rawValue: 3)

  private func packet(_ track: UmbelTrack.ID, at seconds: Double) -> DemuxPacket {
    DemuxPacket(
      trackID: track, data: Data(count: 16),
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
      decodeTime: CMTime(seconds: seconds, preferredTimescale: 600),
      duration: CMTime(seconds: 0.1, preferredTimescale: 600), isKeyframe: true)
  }

  /// Bitmap events each replace the one before, so the past must go in
  /// before anything newer does.
  func testTheReceiverGetsItsPastBeforeAnythingNewer() async throws {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio, subtitleTracks: [english])
    for second in 0..<6 {
      await cache.append(packet(english, at: Double(second)))
      await cache.append(packet(audio, at: Double(second)))
    }
    while let next = await cache.take(from: audio, keeping: [audio]),
      next.presentationTime.seconds < 3
    {}
    let feed = SubtitleFeed(cache: cache)
    let receiver = GatedReceiver()

    let track = english
    let routing = Task { await feed.route(track, to: receiver, previous: nil) }
    var waited = 0
    while await receiver.waiting == 0, waited < 1_000 {
      waited += 1
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    guard await receiver.waiting == 1 else {
      await receiver.open()
      await routing.value
      return XCTFail("the past never went in")
    }
    // While the past is going in, nothing newer may overtake it.
    let delivering = Task {
      await feed.deliver(track, to: receiver, upTo: CMTime(seconds: 5, preferredTimescale: 600))
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    let meanwhile = await receiver.waiting
    XCTAssertEqual(meanwhile, 1, "only the past is at the receiver")
    await receiver.open()
    await routing.value
    await delivering.value
    await feed.deliver(english, to: receiver, upTo: CMTime(seconds: 5, preferredTimescale: 600))

    let received = await receiver.received
    XCTAssertEqual(received, [0, 1, 2, 3, 4, 5])
  }

  func testConcurrentDeliveryPreservesOrderForBothReceiversOfOneTrack() async throws {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio, subtitleTracks: [english])
    for second in 0..<4 { await cache.append(packet(english, at: Double(second))) }
    let feed = SubtitleFeed(cache: cache)
    let first = GatedReceiver()
    let second = GatedReceiver()
    await second.open()
    await feed.route([
      SubtitleRoute(id: english, receiver: first), SubtitleRoute(id: english, receiver: second),
    ])
    let earlier = Task { await feed.deliver(upTo: CMTime(seconds: 1, preferredTimescale: 600)) }
    for _ in 0..<1_000 {
      if await first.waiting > 0 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let waiting = await first.waiting
    XCTAssertEqual(waiting, 1)
    let later = Task { await feed.deliver(upTo: CMTime(seconds: 3, preferredTimescale: 600)) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let stillWaiting = await first.waiting
    XCTAssertEqual(stillWaiting, 1, "a newer packet must not overtake a suspended delivery")
    await first.open()
    await earlier.value
    await later.value
    let firstTimes = await first.received
    let secondTimes = await second.received
    XCTAssertEqual(firstTimes, [0, 1, 2, 3])
    XCTAssertEqual(secondTimes, [0, 1, 2, 3], "taking the queue once must feed both slots")
  }

  func testTheSameReceiverIsNotGivenItsPastAgain() async {
    let cache = PacketCache(configuration: .init(), measuredTrack: audio, subtitleTracks: [english])
    await cache.append(packet(english, at: 0))
    await cache.append(packet(audio, at: 1))
    _ = await cache.take(from: audio, keeping: [audio])
    let feed = SubtitleFeed(cache: cache)
    let receiver = GatedReceiver()
    await receiver.open()
    await feed.route(english, to: receiver, previous: nil)
    await feed.route(english, to: receiver, previous: receiver)
    let received = await receiver.received
    XCTAssertEqual(received, [0], "a new seek generation keeps its receiver")
  }
}
