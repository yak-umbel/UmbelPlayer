import CoreMedia
import XCTest
@testable import UmbelCore

private final class StillHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// A file source that can hold one read the way a stalled connection does,
/// and lets go of it when the task reading is cancelled — what a source
/// written to the protocol's contract does. It stays usable after that.
private actor StallingSource: UmbelRandomAccessSource {
  private let inner: UmbelFileSource
  private var stalledAt: Int64?
  /// Where the stall was put; kept after it is let go.
  private var stallOffset: Int64 = .max
  private(set) var stalledReads = 0
  private(set) var interruptedReads = 0
  private(set) var readsPastStall = 0
  private(set) var isInvalidated = false

  init(fixture name: String) throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
    inner = try UmbelFileSource(url: url)
  }

  /// The read that starts at `offset` holds until `release()`.
  func stall(at offset: Int64) {
    stalledAt = offset
    stallOffset = offset
  }
  func release() { stalledAt = nil }

  var contentLength: Int64? { get async { await inner.contentLength } }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard !isInvalidated else { throw UmbelError.interrupted }
    if let stalledAt, offset == stalledAt {
      stalledReads += 1
      while self.stalledAt == offset {
        do {
          try await Task.sleep(nanoseconds: 10_000_000)
        } catch {
          interruptedReads += 1
          throw UmbelError.interrupted
        }
      }
    }
    // A read that starts before the stall must not run into it either.
    var length = maxLength
    if let stalledAt, offset < stalledAt { length = min(length, Int(stalledAt - offset)) }
    if offset > stallOffset { readsPastStall += 1 }
    return try await inner.read(offset: offset, maxLength: length)
  }

  func invalidate() async {
    isInvalidated = true
    await inner.invalidate()
  }
}

/// Answers byte-range requests for a fixture, except that the first request
/// starting inside the stalled range gets no answer at all, like a connection
/// gone quiet. `stopLoading` on such a request is how the cancelling of it
/// shows.
private final class StallableFileStub: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var content = Data()
  nonisolated(unsafe) private static var stalled: Range<Int> = 0..<0
  nonisolated(unsafe) private static var counts = (stalled: 0, cancelledStalls: 0, answeredAfterStall: 0)

  static func serve(_ data: Data) {
    lock.lock()
    (content, stalled, counts) = (data, 0..<0, (0, 0, 0))
    lock.unlock()
  }

  /// The next request starting in `range` is left unanswered.
  static func stall(_ range: Range<Int>) {
    lock.lock()
    stalled = range
    lock.unlock()
  }

  static var snapshot: (stalled: Int, cancelledStalls: Int, answeredAfterStall: Int) {
    lock.lock()
    defer { lock.unlock() }
    return counts
  }

  private var isStalled = false

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.lock.lock()
    let content = Self.content
    let stalled = Self.stalled
    Self.lock.unlock()
    let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-").dropFirst("bytes=".count)
    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
    let start = Int(parts.first ?? "") ?? 0
    if stalled.contains(start) {
      isStalled = true
      Self.lock.lock()
      Self.counts.stalled += 1
      Self.stalled = 0..<0
      Self.lock.unlock()
      return
    }
    guard start < content.count else {
      let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Range": "bytes */\(content.count)", "Content-Length": "0"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let end = min(Int(parts.count > 1 ? parts[1] : "") ?? content.count - 1, content.count - 1)
    let body = content.subdata(in: start..<(end + 1))
    Self.lock.lock()
    if Self.counts.stalled > 0 { Self.counts.answeredAfterStall += 1 }
    Self.lock.unlock()
    let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
      "Content-Range": "bytes \(start)-\(end)/\(content.count)", "Content-Length": "\(body.count)",
      "Accept-Ranges": "bytes"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    guard isStalled else { return }
    Self.lock.lock()
    Self.counts.cancelledStalls += 1
    Self.lock.unlock()
  }
}

private actor Flag {
  private(set) var isSet = false
  func set() { isSet = true }
}

/// A seek that has to read again does not wait for the read under way: the
/// source is asked to let go of it, and stays in use for the reads after.
final class SeekInterruptsReadTests: XCTestCase {
  /// Reads small enough for a stall to bite where the test puts it; the
  /// default 64 KB would pull in most of the fixture on the first read.
  private let smallReads = DemuxConfiguration(ioBufferSize: 2_048)

  private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

  private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<250 {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting until \(what)")
  }

  func testASeekOutsideTheBufferDoesNotWaitForTheReadUnderWay() async throws {
    let source = try StallingSource(fixture: "seek_grid.mp4")
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: StillHostTime()),
      hostTime: StillHostTime(), configuration: smallReads)
    addTeardownBlock {
      await source.release()
      await session.stop()
    }
    try await session.load()
    // Two seconds in: well short of the target, so the seek has to read again.
    await source.stall(at: 20_000)
    try await session.play()
    await waitUntil("reading is held in the stalled read") { await source.stalledReads > 0 }

    let done = Flag()
    let target = at(8)
    let seeking = Task {
      try await session.seek(to: target)
      await done.set()
    }
    var waited = 0.0
    while waited < 3, !(await done.isSet) {
      try await Task.sleep(nanoseconds: 20_000_000)
      waited += 0.02
    }
    let finishedInTime = await done.isSet
    // Let go either way, so a seek that waits ends and the test does not hang.
    await source.release()
    try await seeking.value

    XCTAssertTrue(finishedInTime, "the seek waited for the stalled read")
    let interrupted = await source.interruptedReads
    XCTAssertEqual(interrupted, 1, "the stalled read was asked to stop")
    let invalidated = await source.isInvalidated
    XCTAssertFalse(invalidated, "interrupting a read does not close the source")
    await waitUntil("reading goes on from the target") { await session.bufferedDuration.seconds > 0 }
    let readsPast = await source.readsPastStall
    XCTAssertGreaterThan(readsPast, 0, "the source answered reads after the interruption")
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed)
  }

  /// Closing is no different: it does not wait for the read under way either.
  func testStoppingDoesNotWaitForTheReadUnderWay() async throws {
    let source = try StallingSource(fixture: "seek_grid.mp4")
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: StillHostTime()),
      hostTime: StillHostTime(), configuration: smallReads)
    addTeardownBlock {
      await source.release()
      await session.stop()
    }
    try await session.load()
    await source.stall(at: 20_000)
    try await session.play()
    await waitUntil("reading is held in the stalled read") { await source.stalledReads > 0 }

    let done = Flag()
    let stopping = Task {
      await session.stop()
      await done.set()
    }
    var waited = 0.0
    while waited < 3, !(await done.isSet) {
      try await Task.sleep(nanoseconds: 20_000_000)
      waited += 0.02
    }
    let finishedInTime = await done.isSet
    // Let go either way, so a stop that waits ends and the test does not hang.
    await source.release()
    await stopping.value

    XCTAssertTrue(finishedInTime, "stopping waited for the stalled read")
    let interrupted = await source.interruptedReads
    XCTAssertEqual(interrupted, 1, "the stalled read was asked to stop")
  }

  /// The same over the network source that ships: the request gone quiet is
  /// cancelled, and the next ones go out on the same source.
  func testASeekOutsideTheBufferCancelsAQuietHTTPRequest() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("seek_grid.mp4")
    StallableFileStub.serve(try Data(contentsOf: fixture))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StallableFileStub.self]
    // Short ranges, so reading in order meets a request starting where the stall is put.
    let diagnostics = UmbelPlaybackDiagnostics()
    let source = UmbelHTTPSource(
      url: URL(string: "http://stub.invalid/seek_grid.mp4")!, session: URLSession(configuration: configuration),
      maximumRangeLength: 8_192)
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: StillHostTime()),
      hostTime: StillHostTime(), configuration: smallReads, diagnostics: diagnostics)
    addTeardownBlock { await session.stop() }
    try await session.load()
    StallableFileStub.stall(20_000..<40_000)
    try await session.play()
    await waitUntil("a request is left unanswered") { StallableFileStub.snapshot.stalled > 0 }

    let done = Flag()
    // Past the end of what is read: the video of this fixture is small enough
    // to be read to nine seconds before the quiet request.
    let target = at(9.5)
    let seeking = Task {
      try await session.seek(to: target)
      await done.set()
    }
    var waited = 0.0
    while waited < 3, !(await done.isSet) {
      try await Task.sleep(nanoseconds: 20_000_000)
      waited += 0.02
    }
    let finishedInTime = await done.isSet
    try await seeking.value

    let paths = diagnostics.snapshot().events.filter { $0.name == "session_seek_path" }.compactMap { $0.labels["path"] }
    XCTAssertEqual(paths, ["reread"], "the target is not in what was read")
    XCTAssertTrue(finishedInTime, "the seek waited for the request gone quiet")
    XCTAssertEqual(StallableFileStub.snapshot.cancelledStalls, 1, "the quiet request was cancelled")
    await waitUntil("a request after the quiet one is answered") { StallableFileStub.snapshot.answeredAfterStall > 0 }
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed)
  }
}
