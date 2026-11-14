import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

private actor RemovalGate {
  private var waiting = false
  private var entry: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func hold() async {
    waiting = true
    entry?.resume()
    entry = nil
    await withCheckedContinuation { release = $0 }
  }

  func waitForEntry() async {
    if waiting { return }
    await withCheckedContinuation { entry = $0 }
  }

  func open() {
    release?.resume()
    release = nil
  }
}

/// A seek request accepted while the audio clock still holds its old position.
private final class DeferredControlTimeline: SystemTimeline, @unchecked Sendable {
  private let lock = NSLock()
  private var requested: CMTime?
  var time: CMTime { CMTime(seconds: 10, preferredTimescale: 600) }
  var handoverTime: CMTime { lock.withLock { requested ?? time } }
  func set(rate: Double, time: CMTime) { lock.withLock { requested = time } }
  func setRate(_ rate: Double) {}
  func add(_ renderer: QueuedRenderer) throws {}
  func remove(_ renderer: QueuedRenderer) async {}
}

/// A timeline standing in for the system's, recording what it is told.
private final class RecordingTimeline: SystemTimeline, @unchecked Sendable {
  private let lock = NSLock()
  private let removal: RemovalGate?
  private var current: CMTime
  private(set) var sets: [(rate: Double, time: CMTime)] = []
  private(set) var rateOnlySets: [Double] = []
  private(set) var added: [ObjectIdentifier] = []
  private(set) var removed: [ObjectIdentifier] = []

  init(time: Double, removal: RemovalGate? = nil) {
    current = CMTime(seconds: time, preferredTimescale: 600)
    self.removal = removal
  }

  var time: CMTime { lock.withLock { current } }
  func move(to seconds: Double) { lock.withLock { current = CMTime(seconds: seconds, preferredTimescale: 600) } }
  func set(rate: Double, time: CMTime) { lock.withLock { sets.append((rate, time)); current = time } }
  func setRate(_ rate: Double) { lock.withLock { rateOnlySets.append(rate) } }
  func add(_ renderer: QueuedRenderer) throws { lock.withLock { added.append(ObjectIdentifier(renderer.renderer)) } }
  func remove(_ renderer: QueuedRenderer) async {
    lock.withLock { removed.append(ObjectIdentifier(renderer.renderer)) }
    await removal?.hold()
  }
}

final class SwitchableTimelineTests: XCTestCase {
  func testItIsTheBaseUntilSwitched() throws {
    let base = RecordingTimeline(time: 3)
    let timeline = SwitchableTimeline(base: base)
    XCTAssertEqual(timeline.time.seconds, 3, accuracy: 1e-9)
    timeline.set(rate: 1, time: CMTime(seconds: 5, preferredTimescale: 600))
    XCTAssertEqual(base.sets.last?.rate, 1)
    XCTAssertEqual(base.sets.last?.time.seconds ?? 0, 5, accuracy: 1e-9)
  }

  /// The pictures go with the timeline in charge; the sound renderer stays on
  /// the synchronizer, the only thing it can follow. The one taking over
  /// starts where the other stood, at its rate; the other stops there.
  func testSwitchingMovesThePicturesAndCarriesTimeAndRate() async throws {
    let base = RecordingTimeline(time: 0)
    let player = RecordingTimeline(time: 0)
    let timeline = SwitchableTimeline(base: base)
    let layer = AVSampleBufferDisplayLayer()
    let sound = AVSampleBufferAudioRenderer()
    try timeline.add(QueuedRenderer(renderer: layer))
    try timeline.add(QueuedRenderer(renderer: sound))
    timeline.set(rate: 1, time: CMTime(seconds: 10, preferredTimescale: 600))

    await timeline.hand(over: player)
    XCTAssertEqual(player.added, [ObjectIdentifier(layer)])
    XCTAssertEqual(base.removed, [ObjectIdentifier(layer)], "the sound renderer is not moved")
    XCTAssertEqual(player.sets.last?.rate, 1)
    XCTAssertEqual(player.sets.last?.time.seconds ?? 0, 10, accuracy: 1e-9)
    XCTAssertEqual(base.sets.last?.rate, 0, "the synchronizer waits where it was")

    player.move(to: 12)
    XCTAssertEqual(timeline.time.seconds, 12, accuracy: 1e-9, "the player's clock is the time now")
    timeline.set(rate: 0, time: CMTime(seconds: 12, preferredTimescale: 600))
    XCTAssertEqual(player.sets.last?.rate, 0)
  }

  func testTakingItBackRestoresTheSynchronizer() async throws {
    let base = RecordingTimeline(time: 0)
    let player = RecordingTimeline(time: 0)
    let timeline = SwitchableTimeline(base: base)
    let layer = AVSampleBufferDisplayLayer()
    try timeline.add(QueuedRenderer(renderer: layer))
    timeline.set(rate: 1, time: .zero)
    await timeline.hand(over: player)
    player.move(to: 20)

    await timeline.takeBack()
    XCTAssertEqual(base.added.last, ObjectIdentifier(layer))
    XCTAssertEqual(player.removed, [ObjectIdentifier(layer)])
    XCTAssertEqual(base.sets.last?.rate, 1)
    XCTAssertEqual(base.sets.last?.time.seconds ?? 0, 20, accuracy: 1e-9)
    XCTAssertEqual(timeline.time.seconds, 20, accuracy: 1e-9)
  }

  func testRateChangeReachesTheActiveTimelineAndSurvivesHandover() async {
    let base = RecordingTimeline(time: 10)
    let player = RecordingTimeline(time: 0)
    let timeline = SwitchableTimeline(base: base)
    timeline.setRate(1.25)
    XCTAssertEqual(base.rateOnlySets, [1.25])
    XCTAssertTrue(base.sets.isEmpty)
    await timeline.hand(over: player)
    XCTAssertEqual(player.sets.last?.rate, 1.25)
    timeline.setRate(2)
    XCTAssertEqual(player.rateOnlySets, [2])
    player.move(to: 12)
    await timeline.takeBack()
    XCTAssertEqual(base.sets.last?.rate, 2)
    XCTAssertEqual(base.sets.last?.time.seconds ?? -1, 12, accuracy: 1e-9)
  }

  func testRateChangeDuringHandoverPreservesTheLatestSeek() async throws {
    let gate = RemovalGate()
    let base = RecordingTimeline(time: 10, removal: gate)
    let incoming = RecordingTimeline(time: 0)
    let timeline = SwitchableTimeline(base: base)
    try timeline.add(QueuedRenderer(renderer: AVSampleBufferDisplayLayer()))
    let switching = Task { await timeline.hand(over: incoming) }
    await gate.waitForEntry()
    timeline.set(rate: 0, time: CMTime(seconds: 42, preferredTimescale: 600))
    timeline.setRate(1.25)
    await gate.open()
    await switching.value
    XCTAssertEqual(incoming.sets.last?.rate, 1.25)
    XCTAssertEqual(timeline.time.seconds, 42, accuracy: 1e-9)
  }

  func testARendererAddedWhileHandedOverGoesToThePlayer() async throws {
    let base = RecordingTimeline(time: 0)
    let player = RecordingTimeline(time: 0)
    let timeline = SwitchableTimeline(base: base)
    await timeline.hand(over: player)
    let layer = AVSampleBufferDisplayLayer()
    try timeline.add(QueuedRenderer(renderer: layer))
    XCTAssertEqual(player.added, [ObjectIdentifier(layer)])
    await timeline.remove(QueuedRenderer(renderer: layer))
    XCTAssertEqual(player.removed, [ObjectIdentifier(layer)])
  }

  func testPauseAndSeekWhileRendererRemovalWaitsTakePrecedence() async throws {
    let gate = RemovalGate()
    let base = RecordingTimeline(time: 10, removal: gate)
    let incoming = RecordingTimeline(time: 0)
    let timeline = SwitchableTimeline(base: base)
    try timeline.add(QueuedRenderer(renderer: AVSampleBufferDisplayLayer()))
    timeline.set(rate: 1, time: CMTime(seconds: 10, preferredTimescale: 600))
    let switching = Task { await timeline.hand(over: incoming) }
    await gate.waitForEntry()
    timeline.set(rate: 0, time: CMTime(seconds: 42, preferredTimescale: 600))
    await gate.open()
    await switching.value
    XCTAssertEqual(timeline.time.seconds, 42, accuracy: 1e-9)
    XCTAssertEqual(incoming.sets.last?.rate, 0, "a handover must not undo a newer pause")
    XCTAssertEqual(incoming.sets.last?.time.seconds ?? -1, 42, accuracy: 1e-9)
  }

  func testSeekAcceptedBeforeHandoverKeepsItsTargetWhileAudioIsStillWaiting() async {
    let base = RecordingTimeline(time: 10)
    let outgoing = DeferredControlTimeline()
    let timeline = SwitchableTimeline(base: base)
    await timeline.hand(over: outgoing)
    timeline.set(rate: 0, time: CMTime(seconds: 42, preferredTimescale: 600))
    await timeline.takeBack()
    XCTAssertEqual(timeline.time.seconds, 42, accuracy: 1e-9)
    XCTAssertEqual(base.sets.last?.rate, 0)
  }
}
