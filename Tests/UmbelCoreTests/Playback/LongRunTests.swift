import CoreMedia
import XCTest
@testable import UmbelCore

private final class FakeHostTime: HostTimeSource, @unchecked Sendable {
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

private func makeSilence(startSeconds: Double, durationSeconds: Double) -> AudioFrame {
  let sampleRate = 48_000.0
  let frameCount = Int(durationSeconds * sampleRate)
  return AudioFrame(
    presentationTime: CMTime(seconds: startSeconds, preferredTimescale: 48_000),
    sampleRate: sampleRate,
    channelCount: 2,
    frameCount: frameCount,
    samples: [Float](repeating: 0, count: frameCount * 2)
  )
}

/// A source that counts its reads, to see whether feeding really stopped.
private actor CountingSource: UmbelRandomAccessSource {
  private let inner: UmbelFileSource
  private var readCount = 0

  init(inner: UmbelFileSource) { self.inner = inner }

  var contentLength: Int64? { get async { await inner.contentLength } }
  var reads: Int { readCount }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    readCount += 1
    return try await inner.read(offset: offset, maxLength: maxLength)
  }

  func invalidate() async { await inner.invalidate() }
}

/// A source that starts failing once opened.
///
/// Failure over a long run is no hypothesis: networks drop and files are
/// pulled. The property to keep is that a failure shows, rather than
/// playback quietly halting.
///
/// Armed after opening rather than failing on the Nth read: N depends on the
/// fixture's size and the buffer's, and would stop meaning anything with
/// another fixture — a 110 KB fixture is read in two or three reads, any
/// larger N never fires, and the test passes falsely.
private actor BreakingSource: UmbelRandomAccessSource {
  private let inner: UmbelFileSource
  private var armed = false

  init(inner: UmbelFileSource) { self.inner = inner }

  var contentLength: Int64? { get async { await inner.contentLength } }

  /// Armed after the container is open, so `load()` completes normally.
  func arm() { armed = true }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    if armed { throw UmbelError.sourceUnavailable(detail: "the fixture fails on purpose") }
    return try await inner.read(offset: offset, maxLength: maxLength)
  }

  func invalidate() async { await inner.invalidate() }
}

private enum Fixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }
}

final class LongRunTests: XCTestCase {
  /// After ten minutes the clock follows the audio, not the host.
  ///
  /// A device a thousandth slow plays only 599.4 seconds of content in 600
  /// seconds of host time. Should host time ever take over, this comes out
  /// 0.6 seconds off — sound and picture plainly apart — and the test catches
  /// it in milliseconds.
  func testClockFollowsAudioAcrossTenMinutes() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, rateFactor: 0.999, maxPendingSeconds: 5)
    let clock = PresentationClock(hostTime: host)
    await clock.setAuthority(.audio)

    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeSilence(startSeconds: 0, durationSeconds: 4))
    try await output.start()
    await clock.setRate(1)

    var fed = 4.0
    var elapsed = 0.0
    let step = 0.5
    while elapsed < 600 {
      host.advance(seconds: step)
      await output.advance(bySeconds: step)
      if let anchor = await output.currentAnchor { await clock.adopt(anchor) }
      // Top up, so the backlog never runs out — running out would stop the
      // audio, and drift would no longer be what is measured.
      if await output.pendingSeconds < 2 {
        try await output.enqueue(makeSilence(startSeconds: fed, durationSeconds: 2))
        fed += 2
      }
      elapsed += step
    }

    let now = await clock.now()
    XCTAssertEqual(now.seconds, 599.4, accuracy: 0.5, "the clock follows the audio")
    XCTAssertLessThan(now.seconds, 599.8, "following the host would be 600; the two have to differ")
  }

  /// Presenting video follows the audio clock too.
  ///
  /// The device's deviation is raised to a hundredth — the real 0.999 is
  /// the last test's — so that what it follows can be told: over ten minutes
  /// the audio moves 594 seconds against the host's 600, about 150 frames
  /// apart at 25 frames a second.
  func testVideoPresentationFollowsAudioNotHost() async throws {
    let host = FakeHostTime()
    let output = VirtualAudioOutput(hostTime: host, rateFactor: 0.99, maxPendingSeconds: 5)
    let clock = PresentationClock(hostTime: host)
    await clock.setAuthority(.audio)
    let queue = VideoFrameQueue(
      capacity: 3, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))

    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try await output.enqueue(makeSilence(startSeconds: 0, durationSeconds: 4))
    try await output.start()
    await clock.setRate(1)

    // One buffer reused: this test cares about time, not pixels.
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 128, cb: 128, cr: 128))
    func frame(at seconds: Double) -> VideoFrame {
      VideoFrame(
        presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
        pixelBuffer: buffer, width: 16, height: 16,
        color: VideoColorDescription(matrix: .bt709, range: .limited))
    }

    let frameInterval = 1.0 / 25.0
    var nextFrameTime = 0.0
    var presented = 0
    var fed = 4.0
    var elapsed = 0.0
    // Each step is a frame interval: a real display loop asks which frame to
    // draw once a frame. With a step far longer, only the latest frame fed
    // within it would be in time, and the rest, late by the queue's rules,
    // would be dropped — drops made by the test.
    let step = frameInterval

    while elapsed < 600 {
      host.advance(seconds: step)
      await output.advance(bySeconds: step)
      if let anchor = await output.currentAnchor { await clock.adopt(anchor) }
      if await output.pendingSeconds < 2 {
        try await output.enqueue(makeSilence(startSeconds: fed, durationSeconds: 2))
        fed += 2
      }

      let now = await clock.now()
      // Feed only up to now, and take it straight away. Feeding further would
      // leave those frames late at the next step and dropped — made by the
      // test, not the behaviour under test.
      while nextFrameTime <= now.seconds {
        if await queue.depth >= 3 {
          // Full: take first to make room, or enqueue waits on backpressure.
          while await queue.take(at: now).frame != nil { presented += 1 }
        }
        await queue.enqueue(frame(at: nextFrameTime))
        nextFrameTime += frameInterval
      }
      while await queue.take(at: now).frame != nil { presented += 1 }
      elapsed += step
    }

    XCTAssertEqual(Double(presented), 594 * 25, accuracy: 60,
                   "about 14850 frames following the audio; 15000 following the host")
    let dropped = await queue.totalDropped
    XCTAssertLessThan(dropped, 25, "frames fed in time are not dropped over and over")
  }

  /// After stopping, feeding really stops.
  ///
  /// A feeding task left hanging shows on a long run as downloading after
  /// stopping, and it holds on to the decoder all along.
  func testStopEndsTheFeeding() async throws {
    let host = FakeHostTime()
    let inner = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let source = CountingSource(inner: inner)
    let session = PlaybackSession(
      source: source,
      audioOutput: VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.5),
      hostTime: host)
    try await session.load()
    try await session.play()
    try await Task.sleep(nanoseconds: 200_000_000)

    await session.stop()
    let atStop = await source.reads
    try await Task.sleep(nanoseconds: 300_000_000)
    let later = await source.reads

    XCTAssertEqual(later, atStop, "not another byte read after stopping")
  }

  /// A read failure is told apart from playing to the end.
  ///
  /// The feed loop was once `catch { break }`: a read failure nine minutes
  /// in looked just like playing to the end. The first demand of a long run
  /// is that when it stops, it can say why.
  ///
  /// The failure is reported once what was read before it has played, so
  /// time is moved on until then.
  func testReadFailureEndsInFailedNotEnded() async throws {
    let host = FakeHostTime()
    let inner = try UmbelFileSource(url: Fixture.url("seek_grid.mp4"))
    let source = BreakingSource(inner: inner)
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 1_000)
    let session = PlaybackSession(source: source, audioOutput: output, hostTime: host)
    try await session.load()
    addTeardownBlock { await session.stop() }
    await source.arm()
    try await session.play()

    for _ in 0..<400 {
      if await session.phase.isTerminal { break }
      host.advance(seconds: 0.25)
      await output.advance(bySeconds: 0.25)
      await session.refreshClock()
      try await Task.sleep(nanoseconds: 5_000_000)
    }

    let phase = await session.phase
    XCTAssertEqual(phase, .failed, "a read failure is told apart from playing to the end")
  }

  /// The queue's depth stays bounded: at 3, never exceeded at any moment of a
  /// long run.
  func testQueueDepthStaysBounded() async throws {
    let queue = VideoFrameQueue(
      capacity: 3, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let buffer = try XCTUnwrap(
      VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 128, cb: 128, cr: 128))

    var worst = 0
    for index in 0..<2_000 {
      let time = CMTime(seconds: Double(index) / 25.0, preferredTimescale: 600)
      await queue.enqueue(
        VideoFrame(presentationTime: time, pixelBuffer: buffer, width: 16, height: 16,
                   color: VideoColorDescription(matrix: .bt709, range: .limited)))
      worst = max(worst, await queue.depth)
      _ = await queue.take(at: time)
    }
    XCTAssertLessThanOrEqual(worst, 3, "the queue never holds more than its capacity")
  }
}
