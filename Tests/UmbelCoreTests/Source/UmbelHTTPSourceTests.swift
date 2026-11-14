import XCTest
@testable import UmbelCore

/// Intercepts requests with URLProtocol rather than running a real server.
///
/// Another reason: tests here once ran into a server in the same process
/// competing with the code under test for one execution context, and never
/// answering. An interceptor has no server loop, which avoids that at the
/// root.
private final class RangeStubProtocol: URLProtocol {
  nonisolated(unsafe) static let payload = Data((0..<256).map { UInt8($0) })

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let payload = Self.payload
    let rangeHeader = request.value(forHTTPHeaderField: "Range")

    var status = 200
    var body = payload
    var headers = ["Content-Length": "\(payload.count)", "Accept-Ranges": "bytes"]

    if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
      let spec = rangeHeader.dropFirst("bytes=".count)
      let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
      let start = Int(parts.first ?? "") ?? 0
      let end = parts.count > 1 ? (Int(parts[1]) ?? payload.count - 1) : payload.count - 1
      if start >= payload.count {
        status = 416
        body = Data()
      } else {
        let clamped = min(end, payload.count - 1)
        status = 206
        body = payload.subdata(in: start..<(clamped + 1))
        headers["Content-Range"] = "bytes \(start)-\(clamped)/\(payload.count)"
        headers["Content-Length"] = "\(body.count)"
      }
    }

    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// A server that ignores Range: whatever range is asked for, 200 and the
/// whole content.
///
/// Common in practice — `python3 -m http.server` is one.
private final class IgnoresRangeStubProtocol: URLProtocol {
  nonisolated(unsafe) static let payload = Data((0..<256).map { UInt8($0) })

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let payload = Self.payload
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": "\(payload.count)"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: payload)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Answers each request to a URL with the next scripted outcome, and counts
/// requests. Keyed by URL so that tests running side by side stay apart.
private final class ScriptedStubProtocol: URLProtocol {
  enum Outcome {
    case transportFailure(URLError.Code)
    /// Any error, passed on as it is: the system does not always say a
    /// transfer failed with a URLError.
    case systemFailure(NSError)
    case status(Int)
    case content
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var scripts: [URL: [Outcome]] = [:]
  nonisolated(unsafe) private static var counts: [URL: Int] = [:]

  static func script(_ url: URL, _ outcomes: [Outcome]) {
    lock.lock(); defer { lock.unlock() }
    scripts[url] = outcomes
    counts[url] = 0
  }

  static func requestCount(for url: URL) -> Int {
    lock.lock(); defer { lock.unlock() }
    return counts[url] ?? 0
  }

  /// The last outcome repeats once the script runs out.
  private static func next(for url: URL) -> Outcome {
    lock.lock(); defer { lock.unlock() }
    counts[url, default: 0] += 1
    var outcomes = scripts[url] ?? [.content]
    let outcome = outcomes.first ?? .content
    if outcomes.count > 1 { outcomes.removeFirst() }
    scripts[url] = outcomes
    return outcome
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    switch Self.next(for: url) {
    case .transportFailure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .systemFailure(let error):
      client?.urlProtocol(self, didFailWithError: error)
    case .status(let status):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case .content:
      let body = Data([1, 2, 3, 4])
      let response = HTTPURLResponse(
        url: url, statusCode: 206, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Range": "bytes 0-3/4", "Content-Length": "4"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

/// A connection gone silent: every request times out. Counts requests per URL.
private final class SilentStubProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var counts: [URL: Int] = [:]

  static func requestCount(for url: URL) -> Int {
    lock.lock(); defer { lock.unlock() }
    return counts[url] ?? 0
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.lock.lock(); Self.counts[url, default: 0] += 1; Self.lock.unlock()
    client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
  }

  override func stopLoading() {}
}

private final class Tally: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
  func add() { lock.lock(); count += 1; lock.unlock() }
}

private final class SomeDelegate: NSObject, URLSessionDelegate {}

/// A timed-out request may leave its connection open in the session's pool,
/// silent, and the next request on that session rides it again. Retries after
/// a timeout go out on a fresh session instead.
final class UmbelHTTPSourceSessionRenewalTests: XCTestCase {
  private let noWait = UmbelHTTPSource.RetryPolicy(maxRetries: 3, initialDelay: 0, offlinePatience: 0)

  private static func session(_ stub: AnyClass, delegate: URLSessionDelegate? = nil) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [stub]
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  private func answering(_ made: Tally) -> @Sendable () -> URLSession {
    { made.add(); return Self.session(RangeStubProtocol.self) }
  }

  func testATimeoutMovesTheRetryToAFreshSession() async throws {
    let url = URL(string: "https://example.invalid/renewal-retry")!
    let made = Tally()
    let source = UmbelHTTPSource(url: url, session: Self.session(SilentStubProtocol.self),
                                 retryPolicy: noWait, makeSession: answering(made))
    let data = try await source.read(offset: 10, maxLength: 4)
    XCTAssertEqual(Array(data), [10, 11, 12, 13])
    XCTAssertEqual(SilentStubProtocol.requestCount(for: url), 1)
    XCTAssertEqual(made.value, 1)
    let renewals = await source.transferStatistics.sessionRenewals
    XCTAssertEqual(renewals, 1)
  }

  /// Segments of a playlist are opened from its source; once one of them has
  /// found the connection silent, the others do not go looking for it again.
  func testSourcesOpenedFromOneShareItsFreshSession() async throws {
    let url = URL(string: "https://example.invalid/renewal-parent")!
    let segment = URL(string: "https://example.invalid/renewal-segment")!
    let made = Tally()
    let parent = UmbelHTTPSource(url: url, session: Self.session(SilentStubProtocol.self),
                                 retryPolicy: noWait, makeSession: answering(made))
    _ = try await parent.read(offset: 0, maxLength: 4)
    let child = await parent.source(for: segment)
    let data = try await child.read(offset: 0, maxLength: 4)
    XCTAssertEqual(Array(data), [0, 1, 2, 3])
    XCTAssertEqual(SilentStubProtocol.requestCount(for: segment), 0)
    XCTAssertEqual(made.value, 1)
  }

  /// Two sources finding the same session silent at once replace it once.
  func testTimeoutsSeenTogetherRenewOnce() async throws {
    let url = URL(string: "https://example.invalid/renewal-together")!
    let other = URL(string: "https://example.invalid/renewal-together-other")!
    let made = Tally()
    let first = UmbelHTTPSource(url: url, session: Self.session(SilentStubProtocol.self),
                                retryPolicy: noWait, makeSession: answering(made))
    let second = await first.source(for: other)
    async let a = first.read(offset: 0, maxLength: 4)
    async let b = second.read(offset: 0, maxLength: 4)
    _ = try await (a, b)
    XCTAssertEqual(made.value, 1)
  }

  /// A server error says nothing about the connection; the session stays.
  func testAServerErrorKeepsTheSession() async throws {
    let url = URL(string: "https://example.invalid/renewal-status")!
    ScriptedStubProtocol.script(url, [.status(503), .content])
    let made = Tally()
    let source = UmbelHTTPSource(url: url, session: Self.session(ScriptedStubProtocol.self),
                                 retryPolicy: noWait, makeSession: answering(made))
    _ = try await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(made.value, 0)
  }

  /// Without a maker, a session with no delegate is renewed from its
  /// configuration: nothing of the caller's is lost by that.
  func testASessionWithoutADelegateIsRenewedFromItsConfiguration() async throws {
    let url = URL(string: "https://example.invalid/renewal-configuration")!
    let source = UmbelHTTPSource(url: url, session: Self.session(SilentStubProtocol.self),
                                 retryPolicy: .init(maxRetries: 1, initialDelay: 0))
    _ = try? await source.read(offset: 0, maxLength: 4)
    let renewals = await source.transferStatistics.sessionRenewals
    XCTAssertEqual(renewals, 2, "each timeout moves later requests to a fresh session")
  }

  /// A delegate may hold the caller's trust or sign-in decisions, which a
  /// session made here would not have; without a maker, the session stays.
  func testASessionWithADelegateIsKeptWithoutAMaker() async throws {
    let url = URL(string: "https://example.invalid/renewal-delegate")!
    let source = UmbelHTTPSource(
      url: url, session: Self.session(SilentStubProtocol.self, delegate: SomeDelegate()),
      retryPolicy: .init(maxRetries: 1, initialDelay: 0))
    _ = try? await source.read(offset: 0, maxLength: 4)
    let renewals = await source.transferStatistics.sessionRenewals
    XCTAssertEqual(renewals, 0)
    XCTAssertEqual(SilentStubProtocol.requestCount(for: url), 2)
  }
}

final class UmbelHTTPSourceRetryTests: XCTestCase {
  private let noWait = UmbelHTTPSource.RetryPolicy(maxRetries: 3, initialDelay: 0, offlinePatience: 0)

  private func scriptedSource(
    _ name: String, _ outcomes: [ScriptedStubProtocol.Outcome],
    policy: UmbelHTTPSource.RetryPolicy? = nil
  ) -> (UmbelHTTPSource, URL) {
    let url = URL(string: "https://example.invalid/\(name)")!
    ScriptedStubProtocol.script(url, outcomes)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScriptedStubProtocol.self]
    let session = URLSession(configuration: configuration)
    return (UmbelHTTPSource(url: url, session: session, retryPolicy: policy ?? noWait), url)
  }

  private func patient(_ patience: TimeInterval, maxRetries: Int = 0, initialDelay: TimeInterval = 0.01)
    -> UmbelHTTPSource.RetryPolicy {
    .init(maxRetries: maxRetries, initialDelay: initialDelay, jitter: 0, offlinePatience: patience)
  }

  /// The device has no network for a while — Wi-Fi dropped, a dead spot —
  /// and says so at once on every request. Waited for, it spends none of
  /// the retries, which a source with none to spend shows.
  func testAnOfflineDeviceIsWaitedForWithoutSpendingRetries() async throws {
    let (source, url) = scriptedSource(
      "offline-waited", Array(repeating: .transportFailure(.notConnectedToInternet), count: 3) + [.content],
      policy: patient(5))
    let data = try await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(Array(data), [1, 2, 3, 4])
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 4)
    let attempts = await source.lastFailure?.attempts
    XCTAssertEqual(attempts, 3, "the third request was the last to fail")
  }

  func testAnOutageLongerThanThePatienceFails() async throws {
    let (source, url) = scriptedSource(
      "offline-too-long", [.transportFailure(.notConnectedToInternet)], policy: patient(0.3))
    let began = Date()
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("an outage past the patience must surface")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .sourceUnavailable(detail: "NSURLErrorDomain error -1009"))
    }
    let elapsed = Date().timeIntervalSince(began)
    XCTAssertGreaterThanOrEqual(elapsed, 0.3)
    XCTAssertLessThan(elapsed, 2)
    XCTAssertGreaterThan(ScriptedStubProtocol.requestCount(for: url), 1)
  }

  /// A minute by default: long enough for a dropped Wi-Fi or a dead spot.
  func testTheDefaultPatienceIsAMinute() {
    XCTAssertEqual(UmbelHTTPSource.RetryPolicy().offlinePatience, 60)
  }

  /// Without patience, as the host may ask, being offline spends retries as
  /// any transient failure does.
  func testWithoutPatienceBeingOfflineSpendsRetries() async throws {
    let (source, url) = scriptedSource("offline-impatient", [.transportFailure(.notConnectedToInternet)])
    _ = try? await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 4)
  }

  /// A lost connection may be the server's going: patience is only for the
  /// device saying it has no network.
  func testPatienceLeavesOtherFailuresToTheRetries() async throws {
    let (source, url) = scriptedSource(
      "offline-other", [.transportFailure(.networkConnectionLost)], policy: patient(5, maxRetries: 1))
    _ = try? await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 2)
  }

  /// A seek or a stop while waiting for the network ends the read at once,
  /// not when the wait or the patience runs out.
  func testInterruptingEndsAnOfflineWait() async throws {
    for action in ["invalidate", "cancel"] {
      let (source, url) = scriptedSource(
        "offline-interrupted-\(action)", [.transportFailure(.notConnectedToInternet)],
        policy: patient(30, initialDelay: 1.5))
      let reading = Task { try await source.read(offset: 0, maxLength: 4) }
      while ScriptedStubProtocol.requestCount(for: url) == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      try await Task.sleep(nanoseconds: 100_000_000)
      let interrupted = Date()
      if action == "invalidate" { await source.invalidate() } else { reading.cancel() }
      do {
        _ = try await reading.value
        XCTFail("\(action): the read must end")
      } catch let error as UmbelError {
        XCTAssertEqual(error, .interrupted, action)
      }
      XCTAssertLessThan(Date().timeIntervalSince(interrupted), 0.5, action)
      XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 1, action)
    }
  }

  /// Errors from below the URL layer, which the system can pass on as they
  /// are rather than as URLErrors: CFNetwork's lost connection (302) and a
  /// connection reset by the peer.
  private let belowURLLayer = [
    NSError(domain: "kCFErrorDomainCFNetwork", code: 302),
    NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET)),
  ]

  /// Whatever its domain, such an error ends a transfer as a lost connection
  /// does, and is retried as one.
  func testAConnectionErrorFromBelowTheURLLayerIsRetried() async throws {
    for error in belowURLLayer {
      for failures in 1...2 {
        let (source, url) = scriptedSource(
          "below-url-layer-\(error.domain)-\(failures)",
          Array(repeating: .systemFailure(error), count: failures) + [.content])
        let data = try await source.read(offset: 0, maxLength: 4)
        XCTAssertEqual(Array(data), [1, 2, 3, 4], "\(error.domain) after \(failures)")
        XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), failures + 1)
      }
    }
  }

  /// Bounded like any other: the first attempt and three retries, then the
  /// error goes up, named by its domain and code, and recorded so.
  func testConnectionErrorsFromBelowTheURLLayerRunOutTheRetries() async throws {
    let (source, url) = scriptedSource("below-url-layer-gives-up", [.systemFailure(belowURLLayer[0])])
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("a failure that never clears must surface")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .sourceUnavailable(detail: "kCFErrorDomainCFNetwork error 302"))
    }
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 4)
    let failure = await source.lastFailure
    XCTAssertEqual(failure?.errorDomain, "kCFErrorDomainCFNetwork")
    XCTAssertEqual(failure?.errorCode, 302)
    XCTAssertNil(failure?.urlErrorCode)
    XCTAssertNil(failure?.httpStatus)
  }

  func testRecoversAfterTransientFailures() async throws {
    let (source, url) = scriptedSource(
      "recovers", [.transportFailure(.networkConnectionLost), .status(503), .content])
    let data = try await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(Array(data), [1, 2, 3, 4])
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 3)
  }

  /// Bounded: the first attempt plus three retries, then the error goes up.
  func testGivesUpAfterTheRetriesRunOut() async throws {
    let (source, url) = scriptedSource("gives-up", [.transportFailure(.timedOut)])
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("a failure that never clears must surface")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 4)
  }

  /// Asking again for something that does not exist changes nothing; it only
  /// delays the error the host needs to see.
  func testDoesNotRetryAClientError() async throws {
    let (source, url) = scriptedSource("not-found", [.status(404)])
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("404 must fail")
    } catch {}
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 1)
  }

  /// What failed, told apart without reading words: the networking error,
  /// no status since no response came, and every request the read made.
  func testTheLastFailureTellsATimeoutApart() async throws {
    let (source, _) = scriptedSource("last-timeout", [.transportFailure(.timedOut)])
    _ = try? await source.read(offset: 2, maxLength: 2)
    let failure = await source.lastFailure
    XCTAssertEqual(failure?.urlErrorCode, .timedOut)
    XCTAssertEqual(failure?.errorDomain, NSURLErrorDomain)
    XCTAssertEqual(failure?.errorCode, -1001)
    XCTAssertNil(failure?.httpStatus)
    XCTAssertEqual(failure?.offset, 2)
    XCTAssertEqual(failure?.attempts, 4)
  }

  /// A refusing status is the server's answer, not a networking error —
  /// even though the source cancels the transfer it will not read.
  func testTheLastFailureTellsARefusalApart() async throws {
    let (source, _) = scriptedSource("last-refusal", [.status(403)])
    _ = try? await source.read(offset: 0, maxLength: 4)
    let failure = await source.lastFailure
    XCTAssertEqual(failure?.httpStatus, 403)
    XCTAssertNil(failure?.urlErrorCode)
    XCTAssertNil(failure?.errorDomain)
    XCTAssertEqual(failure?.attempts, 1)
  }

  func testNoFailureIsReportedWhileNoneHappened() async throws {
    let (source, _) = scriptedSource("no-failure", [.content])
    _ = try await source.read(offset: 0, maxLength: 4)
    let failure = await source.lastFailure
    XCTAssertNil(failure)
  }

  func testDoesNotRetryAfterInvalidation() async throws {
    let (source, url) = scriptedSource("invalidated", [.transportFailure(.timedOut)])
    await source.invalidate()
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("an invalidated source must not read")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .interrupted)
    }
    XCTAssertEqual(ScriptedStubProtocol.requestCount(for: url), 0)
  }

  func testBackoffDoublesFromTheInitialDelay() {
    let policy = UmbelHTTPSource.RetryPolicy(maxRetries: 3, initialDelay: 0.25, jitter: 0)
    XCTAssertEqual(policy.delay(beforeRetry: 1), 0.25, accuracy: 1e-9)
    XCTAssertEqual(policy.delay(beforeRetry: 2), 0.5, accuracy: 1e-9)
    XCTAssertEqual(policy.delay(beforeRetry: 3), 1.0, accuracy: 1e-9)
  }

  /// Many players retrying on the same beat hammer a server that has just
  /// come back; spreading them out is the standard remedy.
  func testJitterStaysWithinItsBand() {
    let policy = UmbelHTTPSource.RetryPolicy(maxRetries: 3, initialDelay: 1, jitter: 0.2)
    for _ in 0..<100 {
      let delay = policy.delay(beforeRetry: 1)
      XCTAssertGreaterThanOrEqual(delay, 0.8)
      XCTAssertLessThanOrEqual(delay, 1.2)
    }
  }
}

final class UmbelHTTPSourceTests: XCTestCase {
  private var session: URLSession!
  private let url = URL(string: "https://example.invalid/media.bin")!

  override func setUp() {
    super.setUp()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeStubProtocol.self]
    session = URLSession(configuration: configuration)
  }

  func testContentLengthComesFromTheFirstResponse() async throws {
    let source = UmbelHTTPSource(url: url, session: session)
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
  }

  func testReadUsesRangeHeader() async throws {
    let source = UmbelHTTPSource(url: url, session: session)
    let data = try await source.read(offset: 10, maxLength: 4)
    XCTAssertEqual(Array(data), [10, 11, 12, 13])
  }

  func testReadIsStateless() async throws {
    let source = UmbelHTTPSource(url: url, session: session)
    _ = try await source.read(offset: 200, maxLength: 8)
    let first = try await source.read(offset: 0, maxLength: 3)
    let second = try await source.read(offset: 0, maxLength: 3)
    XCTAssertEqual(Array(first), [0, 1, 2])
    XCTAssertEqual(first, second)
  }

  func testReadPastEndReturnsEmpty() async throws {
    let source = UmbelHTTPSource(url: url, session: session)
    let data = try await source.read(offset: 300, maxLength: 16)
    XCTAssertTrue(data.isEmpty)
  }

  func testReadAfterInvalidateThrowsInterrupted() async throws {
    let source = UmbelHTTPSource(url: url, session: session)
    await source.invalidate()
    do {
      _ = try await source.read(offset: 0, maxLength: 1)
      XCTFail("reading after invalidate throws")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .interrupted)
    }
  }

  /// Read from the start, a server ignoring Range sends just what was asked
  /// for: the content from byte 0. Playlists are commonly served so — by
  /// scripts and proxies — and their segments are read from the start too.
  func testAServerIgnoringRangeStillServesFromTheStart() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IgnoresRangeStubProtocol.self]
    let source = UmbelHTTPSource(url: url, session: URLSession(configuration: configuration))
    let data = try await source.read(offset: 0, maxLength: 8)
    XCTAssertEqual(Array(data), Array(0..<UInt8(data.count)))
    XCTAssertGreaterThan(data.count, 0)
  }

  /// Its whole content from byte 0 says how long it is, as a range would.
  func testAServerIgnoringRangeStillSaysHowLongItIs() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IgnoresRangeStubProtocol.self]
    let source = UmbelHTTPSource(url: url, session: URLSession(configuration: configuration))
    let length = await source.contentLength
    XCTAssertEqual(length, 256)
  }

  /// A server ignoring Range is refused on the spot, rather than misplaced
  /// bytes being handed on.
  ///
  /// It returns the whole content from byte 0. Handed on as the data at the
  /// offset, the layers above would get misplaced bytes; and every read would
  /// take the whole file into memory. A random-access source needs a server
  /// that takes ranges; without one, say so at once.
  func testServerIgnoringRangeIsRejected() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IgnoresRangeStubProtocol.self]
    let plainSession = URLSession(configuration: configuration)
    let source = UmbelHTTPSource(url: url, session: plainSession)

    do {
      _ = try await source.read(offset: 100, maxLength: 8)
      XCTFail("a server ignoring Range is refused")
    } catch {
      // As expected
    }
  }
}
