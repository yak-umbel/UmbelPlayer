import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore

private final class ManualHost: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    defer { lock.unlock() }
    seconds += delta
  }
}

/// A renderer that takes no frame until let in: video that has not decoded
/// its first picture yet.
private actor GatedRenderer: VideoRenderer {
  private let queue = VideoFrameQueue(capacity: 3, tolerance: CMTime(value: 1, timescale: 50))
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private(set) var received = 0
  var hasBlockedFrame: Bool { !waiting.isEmpty }

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}

  func enqueue(_ frame: VideoFrame) async throws {
    if !isOpen { await withCheckedContinuation { waiting.append($0) } }
    received += 1
    await queue.enqueue(frame)
  }

  func open() {
    isOpen = true
    for continuation in waiting { continuation.resume() }
    waiting = []
  }

  func close() { isOpen = false }

  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    let result = await queue.take(at: time)
    return result.frame.map {
      PresentedFrame(presentationTime: $0.presentationTime, droppedFrames: result.dropped)
    }
  }

  func flush() async {
    await queue.flush()
    // A flush releases a feeder parked here, as the real renderer's does.
    for continuation in waiting { continuation.resume() }
    waiting = []
  }

  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { await queue.totalDropped } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// Sound whose first frame never arrives until let in. A flush lets nothing
/// go: the frame stays in flight, as one still being decoded would.
private actor GatedAudioOutput: AudioOutput {
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Float, muted: Bool) {}
  private let inner: VirtualAudioOutput
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(_ inner: VirtualAudioOutput) { self.inner = inner }

  func open() {
    for continuation in waiting { continuation.resume() }
    waiting = []
  }

  func prepare(sampleRate: Double, channelCount: Int) async throws {
    try await inner.prepare(sampleRate: sampleRate, channelCount: channelCount)
  }

  func enqueue(_ frame: AudioFrame) async throws {
    await withCheckedContinuation { waiting.append($0) }
  }

  func flush() async { await inner.flush() }

  func start() async throws { try await inner.start() }
  func pause() async { await inner.pause() }
  func stop() async { await inner.stop() }
  var currentAnchor: RenderAnchor? { get async { await inner.currentAnchor } }
}

/// The clock starts when every output has its first frame, not only when
/// enough is buffered. Started earlier, it ran on while video was still
/// decoding up to the target, and after every seek the first pictures came
/// late: dropped, and out of step with the sound.
final class FirstFrameStartTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func advance(
    _ session: PlaybackSession, _ host: ManualHost, _ output: VirtualAudioOutput, by seconds: Double
  ) async {
    for _ in 0..<Int(seconds / 0.1) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
  }

  private func loaded() async throws -> (
    PlaybackSession, ManualHost, VirtualAudioOutput, GatedRenderer
  ) {
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let renderer = GatedRenderer()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("seek_grid.mp4")), audioOutput: output,
      videoRenderer: renderer, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    return (session, host, output, renderer)
  }

  private func waitUntil(
    _ description: String, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
  ) async throws -> Bool {
    for _ in 0..<200 {
      if await condition() { return true }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
    return false
  }

  func testTheClockWaitsForTheFirstPicture() async throws {
    let (session, host, output, renderer) = try await loaded()
    try await session.play()
    // Observe both chains before advancing virtual time. Wall-clock sleeps
    // do not establish readiness on a machine building other targets.
    guard try await waitUntil("sound queued and picture blocked", {
      let blocked = await renderer.hasBlockedFrame
      let queued = await output.pendingSeconds
      return blocked && queued >= 1
    }) else { return }
    await advance(session, host, output, by: 1)
    let held = await session.currentTime
    let phase = await session.phase
    XCTAssertEqual(held.seconds, 0, accuracy: 0.001, "no picture yet, no clock")
    XCTAssertEqual(phase, .buffering)

    await renderer.open()
    guard try await waitUntil("playback after the first picture", {
      await session.phase == .playing
    }) else { return }
    await advance(session, host, output, by: 1)
    let running = await session.currentTime
    let playing = await session.phase
    XCTAssertEqual(running.seconds, 1, accuracy: 0.15, "the picture is in; the clock runs")
    XCTAssertEqual(playing, .playing)
  }

  func testAfterASeekTheClockWaitsOnTheTarget() async throws {
    let (session, host, output, renderer) = try await loaded()
    await renderer.open()
    try await session.play()
    guard try await waitUntil("initial playback", {
      await session.phase == .playing
    }) else { return }
    await advance(session, host, output, by: 1)

    await renderer.close()
    try await session.seek(to: CMTime(seconds: 12, preferredTimescale: 600))
    guard try await waitUntil("picture blocked after seek", {
      let blocked = await renderer.hasBlockedFrame
      let queued = await output.pendingSeconds
      return blocked && queued >= 1
    }) else { return }
    await advance(session, host, output, by: 1)
    let held = await session.currentTime
    XCTAssertEqual(held.seconds, 12, accuracy: 0.001, "held on the target")

    await renderer.open()
    guard try await waitUntil("playback after seeking", {
      await session.phase == .playing
    }) else { return }
    await advance(session, host, output, by: 1)
    let running = await session.currentTime
    XCTAssertEqual(running.seconds, 13, accuracy: 0.15)
  }

  /// Sound switched off before its first frame is in: the picture plays on
  /// its own, rather than waiting for sound that will never come.
  func testSoundSwitchedOffIsNotWaitedFor() async throws {
    let host = ManualHost()
    let output = GatedAudioOutput(VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000))
    let renderer = GatedRenderer()
    await renderer.open()
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("seek_grid.mp4")), audioOutput: output,
      videoRenderer: renderer, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    // Runs first: stopping waits for the frame in flight.
    addTeardownBlock { await output.open() }
    try await session.play()
    try await Task.sleep(nanoseconds: 300_000_000)
    let waiting = await session.phase
    XCTAssertEqual(waiting, .buffering, "the picture is in; the sound is not")

    try await session.selectAudioTrack(nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    host.advance(seconds: 1)
    let running = await session.currentTime
    XCTAssertEqual(running.seconds, 1, accuracy: 0.05)
  }

  /// A seek so close to the end that video has nothing left to show still
  /// plays out, and ends.
  func testAChainThatEndsCountsAsReady() async throws {
    let (session, host, output, renderer) = try await loaded()
    await renderer.open()
    try await session.play()
    try await session.seek(to: CMTime(seconds: 29.99, preferredTimescale: 600))
    for _ in 0..<100 {
      if await session.phase == .ended { break }
      await advance(session, host, output, by: 0.1)
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let phase = await session.phase
    XCTAssertEqual(phase, .ended)
  }
}
