import XCTest
@testable import UmbelCore

/// Answers by script, per path: what each request to it gets, the last reply
/// standing for every request after. No server in the process.
private final class LiveStubProtocol: URLProtocol {
  enum End {
    case finish
    /// Never ends by itself: more bytes come from `push`, and the transfer
    /// is cut by `cut`. A failure made in the same call as the bytes is not
    /// offered: the system lets it overtake bytes not yet handed to the
    /// delegate, so what a test reads first would be luck.
    case hang
  }

  enum Reply {
    case body([Data], end: End, contentLength: Int? = nil)
    case status(Int)
    case failure(URLError.Code)
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var scripts: [String: [Reply]] = [:]
  nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]
  nonisolated(unsafe) private static var open: [String: LiveStubProtocol] = [:]
  nonisolated(unsafe) private static var cancelled: Set<String> = []

  static func script(_ path: String, _ replies: [Reply]) {
    lock.lock(); defer { lock.unlock() }
    scripts[path] = replies
    seen[path] = []
    open[path] = nil
    cancelled.remove(path)
  }

  static func requests(_ path: String) -> [URLRequest] {
    lock.lock(); defer { lock.unlock() }
    return seen[path] ?? []
  }

  static func wasCancelled(_ path: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled.contains(path)
  }

  /// More bytes on the transfer that is hanging.
  static func push(_ data: Data, to path: String) {
    lock.lock()
    let target = open[path]
    lock.unlock()
    if let target { target.client?.urlProtocol(target, didLoad: data) }
  }

  /// Ends the transfer that is hanging, as a connection that was lost.
  static func cut(_ code: URLError.Code = .networkConnectionLost, path: String) {
    lock.lock()
    let target = open[path]
    open[path] = nil
    lock.unlock()
    if let target { target.client?.urlProtocol(target, didFailWithError: URLError(code)) }
  }

  private var hangingPath: String?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let path = url.path
    Self.lock.lock()
    let index = Self.seen[path, default: []].count
    Self.seen[path, default: []].append(request)
    let replies = Self.scripts[path] ?? []
    Self.lock.unlock()
    guard !replies.isEmpty else { return }
    switch replies[min(index, replies.count - 1)] {
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .status(let code):
      respond(url: url, status: code, contentLength: nil)
      client?.urlProtocolDidFinishLoading(self)
    case .body(let chunks, let end, let contentLength):
      respond(url: url, status: 200, contentLength: contentLength)
      for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
      switch end {
      case .finish:
        client?.urlProtocolDidFinishLoading(self)
      case .hang:
        hangingPath = path
        Self.lock.lock(); Self.open[path] = self; Self.lock.unlock()
      }
    }
  }

  private func respond(url: URL, status: Int, contentLength: Int?) {
    var headers = ["Content-Type": "video/mp2t"]
    if let contentLength { headers["Content-Length"] = "\(contentLength)" }
    guard let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }

  override func stopLoading() {
    guard let hangingPath else { return }
    Self.lock.lock()
    Self.open[hangingPath] = nil
    Self.cancelled.insert(hangingPath)
    Self.lock.unlock()
  }
}

private final class Finished: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock(); defer { lock.unlock() }
    return value
  }

  func set() { lock.lock(); value = true; lock.unlock() }
}

private final class PacingTally: @unchecked Sendable {
  private let lock = NSLock()
  private var holds = 0
  private var releases = 0

  var counts: (holds: Int, releases: Int) {
    lock.lock(); defer { lock.unlock() }
    return (holds, releases)
  }

  func held() { lock.lock(); holds += 1; lock.unlock() }
  func released() { lock.lock(); releases += 1; lock.unlock() }
}

final class UmbelLiveHTTPSourceTests: XCTestCase {
  private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LiveStubProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func source(
    _ path: String, _ replies: [LiveStubProtocol.Reply], headers: [String: String] = [:],
    startRetries: Int = 2, pacing: HTTPRangeStream.Pacing = .init()
  ) throws -> UmbelLiveHTTPSource {
    LiveStubProtocol.script(path, replies)
    let url = try XCTUnwrap(URL(string: "http://live.invalid\(path)"))
    return UmbelLiveHTTPSource(
      url: url, headers: headers, session: session(), startRetries: startRetries, startRetryDelay: 0.01,
      pacing: pacing)
  }

  private func readAll(_ source: UmbelLiveHTTPSource) async throws -> Data {
    var all = Data()
    while true {
      let next = try await source.readNext(maxLength: 1 << 16)
      if next.isEmpty { return all }
      all += next
    }
  }

  private func failure(of source: UmbelLiveHTTPSource) async -> UmbelError? {
    do {
      _ = try await source.readNext(maxLength: 16)
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  func testABodyIsReadInOrderAndEndsAtItsEnd() async throws {
    let live = try source("/ends", [.body([Data([1, 2, 3]), Data([4, 5])], end: .finish)])
    let all = try await readAll(live)
    XCTAssertEqual(all, Data([1, 2, 3, 4, 5]))
    let again = try await live.readNext(maxLength: 16)
    XCTAssertEqual(again, Data(), "the end stays the end")
    let length = await live.contentLength
    XCTAssertNil(length, "a live stream has no length, whatever the server says")
  }

  /// A server that ignores ranges cannot be asked for one, and a live stream
  /// has no offset to ask from: the request says neither, and says what the
  /// host's headers do.
  func testNoRangeIsAskedForAndTheHostsHeadersGoOut() async throws {
    let live = try source("/headers", [.body([Data([1])], end: .finish)], headers: ["X-Site": "one"])
    _ = try await readAll(live)
    let request = try XCTUnwrap(LiveStubProtocol.requests("/headers").first)
    XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Site"), "one")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
  }

  func testATruncatedBodyIsAFailureNotAnEnd() async throws {
    let live = try source("/short", [.body([Data([1, 2, 3, 4, 5])], end: .finish, contentLength: 10)])
    let first = try await live.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1, 2, 3, 4, 5]))
    let error = await failure(of: live)
    XCTAssertEqual(error, .sourceUnavailable(detail: "HTTP body ended early"))
  }

  /// The transfer cut after bytes were delivered is not resumed: a live stream
  /// has nothing to resume from, and the host decides whether to open again.
  func testACutAfterBytesIsAnErrorAndNeverResumed() async throws {
    let live = try source("/cut", [.body([Data([1, 2])], end: .hang)])
    let first = try await live.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1, 2]))
    LiveStubProtocol.cut(path: "/cut")
    let second = await failure(of: live)
    XCTAssertEqual(second, .sourceUnavailable(detail: "NSURLErrorDomain error -1005"))
    let third = await failure(of: live)
    XCTAssertEqual(third, .sourceUnavailable(detail: "NSURLErrorDomain error -1005"))
    XCTAssertEqual(LiveStubProtocol.requests("/cut").count, 1, "no second request, with a range or without")
  }

  func testAFailureBeforeTheFirstByteIsRetried() async throws {
    let live = try source("/retries", [
      .failure(.networkConnectionLost), .status(503), .body([Data([7])], end: .finish),
    ])
    let all = try await readAll(live)
    XCTAssertEqual(all, Data([7]))
    XCTAssertEqual(LiveStubProtocol.requests("/retries").count, 3)
  }

  func testRetriesBeforeTheFirstByteAreLimited() async throws {
    let live = try source("/gives-up", [.failure(.cannotConnectToHost)], startRetries: 2)
    let error = await failure(of: live)
    XCTAssertEqual(error, .sourceUnavailable(detail: "NSURLErrorDomain error -1004"))
    XCTAssertEqual(LiveStubProtocol.requests("/gives-up").count, 3, "the first, and two retries")
  }

  func testWhatCanNeverSucceedIsNotRetried() async throws {
    let live = try source("/gone", [.status(404)])
    let error = await failure(of: live)
    XCTAssertEqual(error, .sourceUnavailable(detail: "HTTP 404"))
    XCTAssertEqual(LiveStubProtocol.requests("/gone").count, 1)
  }

  func testASchemeTheSessionCannotReadIsNamedAndNotRetried() async throws {
    let url = try XCTUnwrap(URL(string: "rtmp://live.invalid/app/stream?token=secret"))
    let live = UmbelLiveHTTPSource(
      url: url, session: URLSession(configuration: .ephemeral), startRetries: 2, startRetryDelay: 0.01)
    let error = await failure(of: live)
    XCTAssertEqual(error, .unsupportedScheme("rtmp"))
    XCTAssertEqual((error)?.isRetryable, false)
  }

  /// A read given up on is not the stream ending: what comes next is read.
  func testCancellingAReadDoesNotEndTheStream() async throws {
    let live = try source("/cancel-read", [.body([Data([1])], end: .hang)])
    let first = try await live.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1]))
    let waiting = Task { try await live.readNext(maxLength: 16) }
    try await Task.sleep(nanoseconds: 100_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled read gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    LiveStubProtocol.push(Data([2, 3]), to: "/cancel-read")
    let next = try await live.readNext(maxLength: 16)
    XCTAssertEqual(next, Data([2, 3]))
    await live.invalidate()
  }

  func testInvalidatingEndsTheReadWaitingAndEveryOneAfter() async throws {
    let live = try source("/invalidate", [.body([], end: .hang)])
    let waiting = Task { try await live.readNext(maxLength: 16) }
    try await Task.sleep(nanoseconds: 100_000_000)
    await live.invalidate()
    do {
      _ = try await waiting.value
      XCTFail("an invalidated source gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    let after = await failure(of: live)
    XCTAssertEqual(after, .interrupted)
    await live.invalidate()
    for _ in 0..<100 where !LiveStubProtocol.wasCancelled("/invalidate") {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(LiveStubProtocol.wasCancelled("/invalidate"), "the connection is let go")
  }

  /// A host that lets the source go without invalidating it has not left the
  /// connection open for good.
  func testReleasingTheSourceLetsTheConnectionGo() async throws {
    LiveStubProtocol.script("/release", [.body([Data([1])], end: .hang)])
    do {
      let url = try XCTUnwrap(URL(string: "http://live.invalid/release"))
      let live = UmbelLiveHTTPSource(url: url, session: session())
      let first = try await live.readNext(maxLength: 16)
      XCTAssertEqual(first, Data([1]))
    }
    for _ in 0..<200 where !LiveStubProtocol.wasCancelled("/release") {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(LiveStubProtocol.wasCancelled("/release"), "the connection is let go")
  }

  func testATransferIsHeldWhenReadsFallBehindAndLetGoOnWhenTheyCatchUp() async throws {
    let tally = PacingTally()
    let pacing = HTTPRangeStream.Pacing(hold: { _ in tally.held() }, release: { _ in tally.released() })
    let chunk = Data(repeating: 0, count: 64 << 10)
    let live = try source(
      "/pacing", [.body(Array(repeating: chunk, count: 72), end: .hang)], pacing: pacing)
    _ = try await live.readNext(maxLength: 1)
    for _ in 0..<100 where tally.counts.holds == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(tally.counts.holds, 1, "4.5 MiB buffered is past the high watermark")
    XCTAssertEqual(tally.counts.releases, 0)
    var read = 1
    while read < 4_000_000 { read += try await live.readNext(maxLength: 1 << 16).count }
    XCTAssertEqual(tally.counts.releases, 1, "under the low watermark again")
    await live.invalidate()
  }

  /// Through the demuxer, as a session would: a stream read in order is not
  /// seekable, and one cut short ends in a source error, not a silent stop.
  func testADemuxerReadsALiveStreamAndSaysItCannotSeek() async throws {
    let payload = try Data(contentsOf: Self.fixture("live_like.ts"))
    let live = try source("/demux", [.body(Self.chunks(of: payload), end: .finish)])
    let demux = DemuxSession(source: live)
    try await demux.open()
    let seekable = await demux.isSeekable
    XCTAssertFalse(seekable)
    var packets = 0
    while try await demux.nextPacket() != nil { packets += 1 }
    XCTAssertGreaterThan(packets, 0)
    await demux.close()
  }

  func testADemuxerOverAStreamCutShortFailsWithASourceError() async throws {
    let payload = try Data(contentsOf: Self.fixture("live_like.ts"))
    let half = Data(payload.prefix(payload.count / 2))
    let live = try source("/demux-cut", [.body(Self.chunks(of: half), end: .hang)])
    let demux = DemuxSession(source: live)
    let done = Finished()
    let reading = Task { () -> Error? in
      defer { done.set() }
      do {
        try await demux.open()
        while try await demux.nextPacket() != nil {}
        return nil
      } catch {
        return error
      }
    }
    // The bytes have long been handed over by now; then the connection goes.
    try await Task.sleep(nanoseconds: 300_000_000)
    LiveStubProtocol.cut(path: "/demux-cut")
    // Bounded: a source that carried on after the cut would hold the test for good.
    for _ in 0..<500 where !done.isSet { try await Task.sleep(nanoseconds: 10_000_000) }
    if !done.isSet {
      await demux.close()
      XCTFail("the cut did not end the read")
    }
    let failed = await reading.value
    guard case .sourceUnavailable? = failed as? UmbelError else {
      return XCTFail("a cut stream ends as a source failure, not as \(String(describing: failed))")
    }
    await demux.close()
  }

  private static func chunks(of data: Data) -> [Data] {
    stride(from: 0, to: data.count, by: 1316).map { Data(data[$0..<min($0 + 1316, data.count)]) }
  }

  private static func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }
}
