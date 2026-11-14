import XCTest
@testable import UmbelCore

/// A server on a slow link: it answers ranges from `content`, but holds back
/// every byte in `withheld` until let go — what comes before arrives at once,
/// and then the connection waits, as it would for the network. It can also
/// time a connection out once, after so many bytes of a response — a timeout
/// rather than a lost connection, which URLSession retries from the start by
/// itself before anything above sees it.
private final class TrickleProtocol: URLProtocol {
  struct Setup {
    var content: Data
    var withheld: Range<Int> = 0..<0
    var dropAfter: Int?
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var setups: [URL: Setup] = [:]
  nonisolated(unsafe) private static var released: Set<URL> = []
  nonisolated(unsafe) private static var logs: [URL: [String]] = [:]

  static func serve(_ url: URL, _ setup: Setup) {
    lock.lock(); defer { lock.unlock() }
    setups[url] = setup
    released.remove(url)
    logs[url] = []
  }

  static func release(_ url: URL) {
    lock.lock(); defer { lock.unlock() }
    released.insert(url)
  }

  /// "HEAD", or "GET <range>" for each request, in order.
  static func requests(_ url: URL) -> [String] {
    lock.lock(); defer { lock.unlock() }
    return logs[url] ?? []
  }

  private static func begin(_ url: URL, _ entry: String) -> Setup? {
    lock.lock(); defer { lock.unlock() }
    logs[url, default: []].append(entry)
    return setups[url]
  }

  /// Takes the drop, so it happens once.
  private static func takeDrop(_ url: URL) -> Int? {
    lock.lock(); defer { lock.unlock() }
    let drop = setups[url]?.dropAfter
    setups[url]?.dropAfter = nil
    return drop
  }

  private static func isReleased(_ url: URL) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return released.contains(url)
  }

  private let stateLock = NSLock()
  nonisolated(unsafe) private var stopped = false
  /// Client calls go to the thread loading started on, as URLProtocol wants;
  /// made from elsewhere, data could be overtaken by a failure sent after it.
  nonisolated(unsafe) private var loadingThread: Thread?

  private var isStopped: Bool {
    stateLock.lock(); defer { stateLock.unlock() }
    return stopped
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    loadingThread = Thread.current
    guard let url = request.url else { return }
    let range = request.value(forHTTPHeaderField: "Range") ?? ""
    let isHead = request.httpMethod == "HEAD"
    guard let setup = Self.begin(url, isHead ? "HEAD" : "GET \(range)") else { return }
    let count = setup.content.count

    if isHead {
      respond(url, 200, ["Content-Length": "\(count)"])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    var start = 0
    var end = count - 1
    if range.hasPrefix("bytes=") {
      let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
      start = Int(parts[0]) ?? 0
      if parts.count > 1, let last = Int(parts[1]) { end = min(last, count - 1) }
    }
    if start >= count {
      respond(url, 416, ["Content-Range": "bytes */\(count)", "Content-Length": "0"])
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    respond(url, 206, [
      "Content-Range": "bytes \(start)-\(end)/\(count)",
      "Content-Length": "\(end - start + 1)",
    ])
    let drop = Self.takeDrop(url)
    DispatchQueue.global().async { self.feed(url, setup, from: start, to: end, dropAfter: drop) }
  }

  private func respond(_ url: URL, _ status: Int, _ headers: [String: String]) {
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
  }

  private func feed(_ url: URL, _ setup: Setup, from start: Int, to end: Int, dropAfter: Int?) {
    var position = start
    while position <= end {
      if isStopped { return }
      if let dropAfter, position - start >= dropAfter {
        // Lets what was sent reach the task first: URLSession can drop data
        // still on its way when a failure overtakes it.
        Thread.sleep(forTimeInterval: 0.05)
        onLoadingThread(#selector(sendFailure))
        return
      }
      if setup.withheld.contains(position), !Self.isReleased(url) {
        Thread.sleep(forTimeInterval: 0.005)
        continue
      }
      var limit = min(end + 1, position + 16_384)
      if position < setup.withheld.lowerBound { limit = min(limit, setup.withheld.lowerBound) }
      if let dropAfter { limit = min(limit, start + dropAfter) }
      onLoadingThread(#selector(send(_:)), setup.content.subdata(in: position..<limit) as NSData)
      position = limit
    }
    onLoadingThread(#selector(sendFinish))
  }

  private func onLoadingThread(_ selector: Selector, _ argument: Any? = nil) {
    guard let thread = loadingThread, !isStopped else { return }
    perform(selector, on: thread, with: argument, waitUntilDone: true,
            modes: [RunLoop.Mode.default.rawValue])
  }

  @objc private func send(_ data: NSData) {
    if !isStopped { client?.urlProtocol(self, didLoad: data as Data) }
  }

  @objc private func sendFailure() {
    if !isStopped { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
  }

  @objc private func sendFinish() {
    if !isStopped { client?.urlProtocolDidFinishLoading(self) }
  }

  override func stopLoading() {
    stateLock.lock(); defer { stateLock.unlock() }
    stopped = true
  }
}

private struct TimedOut: Error {}

/// Counts how often a stream holds its transfer back and lets it go on.
private final class PacingLog: @unchecked Sendable {
  private let lock = NSLock()
  private var holds = 0
  private var releases = 0

  var counts: (holds: Int, releases: Int) {
    lock.lock(); defer { lock.unlock() }
    return (holds, releases)
  }

  var pacing: HTTPRangeStream.Pacing {
    HTTPRangeStream.Pacing(
      hold: { _ in self.lock.lock(); self.holds += 1; self.lock.unlock() },
      release: { _ in self.lock.lock(); self.releases += 1; self.lock.unlock() })
  }
}

/// Lets exactly one of two racers answer.
private final class Answered: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false

  func claim() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}

/// Network reads are streamed: bytes are handed on as they arrive, not once a
/// whole block has. Waiting for a whole mebibyte before the first byte cost a
/// second of start on a slow link, where opening a film needs a few hundred
/// kilobytes.
final class StreamingReadTests: XCTestCase {
  private var urls: [URL] = []

  override func tearDown() {
    for url in urls { TrickleProtocol.release(url) }
    super.tearDown()
  }

  private func serving(_ name: String, _ setup: TrickleProtocol.Setup) -> (UmbelHTTPSource, URL) {
    let (session, url) = stubbed(name, setup)
    let noWait = UmbelHTTPSource.RetryPolicy(maxRetries: 3, initialDelay: 0)
    return (UmbelHTTPSource(url: url, session: session, retryPolicy: noWait), url)
  }

  private func stubbed(_ name: String, _ setup: TrickleProtocol.Setup) -> (URLSession, URL) {
    let url = URL(string: "https://example.invalid/\(name)-\(UUID().uuidString)")!
    urls.append(url)
    TrickleProtocol.serve(url, setup)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TrickleProtocol.self]
    return (URLSession(configuration: configuration), url)
  }

  private func content(_ count: Int) -> Data {
    Data((0..<count).map { UInt8($0 % 251) })
  }

  /// Fails the test rather than hanging it, if `body` does not finish in
  /// time. Does not wait for `body` to notice: a read stuck on the network
  /// does not heed cancellation, and tearDown lets the server go on.
  private func within<T: Sendable>(
    _ seconds: Double, _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let answered = Answered()
    return try await withCheckedThrowingContinuation { continuation in
      Task {
        do {
          let value = try await body()
          if answered.claim() { continuation.resume(returning: value) }
        } catch {
          if answered.claim() { continuation.resume(throwing: error) }
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if answered.claim() { continuation.resume(throwing: TimedOut()) }
      }
    }
  }

  private static func readAll(_ source: UmbelHTTPSource, from start: Int64, piece: Int) async throws -> Data {
    var data = Data()
    while true {
      let next = try await source.read(offset: start + Int64(data.count), maxLength: piece)
      if next.isEmpty { return data }
      data.append(next)
    }
  }

  func testAReadHandsOverWhatHasArrived() async throws {
    let body = content(256 * 1024)
    let (source, _) = serving("arrived", .init(content: body, withheld: 65_536..<body.count))
    let data = try await within(3) { try await source.read(offset: 0, maxLength: body.count) }
    XCTAssertGreaterThan(data.count, 0)
    XCTAssertLessThanOrEqual(data.count, 65_536, "nothing from what has not arrived")
    XCTAssertEqual(data, body.prefix(data.count))
  }

  func testReadingOnInOrderTakesOneRequest() async throws {
    let body = content(200_000)
    let (source, url) = serving("inorder", .init(content: body))
    let data = try await Self.readAll(source, from: 0, piece: 16_384)
    XCTAssertEqual(data, body)
    let gets = TrickleProtocol.requests(url).filter { $0.hasPrefix("GET") }
    XCTAssertEqual(gets.count, 1, "one connection read through")
  }

  func testReadingElsewhereOpensAnotherRequest() async throws {
    let body = content(200_000)
    let (source, url) = serving("elsewhere", .init(content: body))
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let there = try await source.read(offset: 150_000, maxLength: 1_000)
    XCTAssertEqual(there, body.subdata(in: 150_000..<(150_000 + there.count)))
    let gets = TrickleProtocol.requests(url).filter { $0.hasPrefix("GET") }
    XCTAssertEqual(gets, ["GET bytes=0-", "GET bytes=150000-"])
  }

  /// A broken connection carries on from where it broke. The reader lags
  /// here, so the break comes while bytes are still unread: those are read
  /// first, then the connection is opened again after them.
  func testAConnectionBrokenMidwayCarriesOnFromWhereItBroke() async throws {
    let body = content(200_000)
    let (source, url) = serving("dropped", .init(content: body, dropAfter: 50_000))
    var data = try await source.read(offset: 0, maxLength: 1)
    try await Task.sleep(nanoseconds: 200_000_000)
    data.append(try await Self.readAll(source, from: 1, piece: 16_384))
    XCTAssertEqual(data, body)
    let gets = TrickleProtocol.requests(url).filter { $0.hasPrefix("GET") }
    XCTAssertEqual(gets.count, 2)
    XCTAssertEqual(gets.last, "GET bytes=50000-", "on from where it broke")
  }

  func testFiniteRangeReturnsAvailableBytesBeforeItsFullBody() async throws {
    let body = content(8_000)
    let (session, url) = stubbed("finite-short", .init(content: body, withheld: 1_024..<body.count))
    let source = UmbelHTTPSource(url: url, session: session, maximumRangeLength: 4_096)
    let first = try await within(3) { try await source.read(offset: 0, maxLength: 4_096) }
    XCTAssertGreaterThan(first.count, 0)
    XCTAssertLessThanOrEqual(first.count, 1_024)
    XCTAssertEqual(first, body.prefix(first.count))
    XCTAssertEqual(TrickleProtocol.requests(url), ["GET bytes=0-4095"])
    TrickleProtocol.release(url)
    var all = first
    all.append(try await Self.readAll(source, from: Int64(first.count), piece: 4_096))
    XCTAssertEqual(all, body)
    XCTAssertEqual(TrickleProtocol.requests(url), ["GET bytes=0-4095", "GET bytes=4096-8191"])
  }

  func testInterruptedFiniteBodyRetriesFromTheNextUndeliveredByte() async throws {
    let body = content(130_000)
    let (session, url) = stubbed("finite-drop", .init(content: body, dropAfter: 50_000))
    let source = UmbelHTTPSource(
      url: url, session: session,
      retryPolicy: .init(maxRetries: 3, initialDelay: 0, jitter: 0),
      maximumRangeLength: 65_536)
    let all = try await Self.readAll(source, from: 0, piece: 16_384)
    XCTAssertEqual(all, body)
    XCTAssertEqual(TrickleProtocol.requests(url), [
      "GET bytes=0-65535", "GET bytes=50000-115535", "GET bytes=115536-181071",
    ])
    let totals = await source.transferStatistics
    XCTAssertEqual(totals.requestCount, 3)
    XCTAssertEqual(totals.receivedBytes, Int64(body.count))
    XCTAssertEqual(totals.deliveredBytes, Int64(body.count))
    XCTAssertEqual(totals.bufferedBytes, 0)
  }

  /// Invalidating wakes a read waiting on the network; closing a session
  /// stuck on a stalled link must not hang.
  func testInvalidatingWakesAWaitingRead() async throws {
    let body = content(100_000)
    let (source, _) = serving("stalled", .init(content: body, withheld: 1_000..<body.count))
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let waiting = Task { try await source.read(offset: 1_000, maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 100_000_000)
    await source.invalidate()
    let outcome = try await within(2) { await waiting.result }
    XCTAssertThrowsError(try outcome.get()) { error in
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
  }

  func testInvalidatingWakesAWaitingFiniteReadAndRetainsTotals() async throws {
    let body = content(100_000)
    let (session, url) = stubbed("finite-stalled", .init(content: body, withheld: 1_000..<body.count))
    let source = UmbelHTTPSource(url: url, session: session, maximumRangeLength: 4_096)
    let first = try await source.read(offset: 0, maxLength: 1_000)
    XCTAssertEqual(first.count, 1_000)
    let waiting = Task { try await source.read(offset: 1_000, maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 100_000_000)
    await source.invalidate()
    let result = try await within(2) { await waiting.result }
    XCTAssertThrowsError(try result.get()) { error in
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    let totals = await source.transferStatistics
    XCTAssertEqual(totals.requestCount, 1)
    XCTAssertEqual(totals.receivedBytes, 1_000)
    XCTAssertEqual(totals.deliveredBytes, 1_000)
    XCTAssertEqual(totals.bufferedBytes, 0)
  }

  func testCancellingAWaitingFiniteReadWakesIt() async throws {
    let body = content(100_000)
    let (session, url) = stubbed("finite-cancel", .init(content: body, withheld: 1_000..<body.count))
    let source = UmbelHTTPSource(url: url, session: session, maximumRangeLength: 4_096)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let waiting = Task { try await source.read(offset: 1_000, maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 100_000_000)
    waiting.cancel()
    let result = try await within(2) { await waiting.result }
    XCTAssertThrowsError(try result.get()) { error in
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    TrickleProtocol.release(url)
    let resumed = try await source.read(offset: 1_000, maxLength: 1_000)
    XCTAssertEqual(resumed, body.subdata(in: 1_000..<(1_000 + resumed.count)))
    XCTAssertEqual(TrickleProtocol.requests(url), ["GET bytes=0-4095", "GET bytes=1000-5095"])
  }

  func testInvalidationWakesEveryConcurrentWaitingRead() async throws {
    let body = content(100_000)
    let (session, url) = stubbed("finite-two-waiters", .init(content: body, withheld: 1_000..<body.count))
    let source = UmbelHTTPSource(url: url, session: session, maximumRangeLength: 4_096)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let first = Task { try await source.read(offset: 1_000, maxLength: 1_000) }
    let second = Task { try await source.read(offset: 1_000, maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 100_000_000)
    await source.invalidate()
    let firstResult = try await within(2) { await first.result }
    let secondResult = try await within(2) { await second.result }
    XCTAssertThrowsError(try firstResult.get()) { error in
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertThrowsError(try secondResult.get()) { error in
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
  }

  func testTheReceiveBufferIsBounded() {
    XCTAssertTrue(HTTPRangeStream.shouldPause(buffered: HTTPRangeStream.pauseAbove + 1))
    XCTAssertFalse(HTTPRangeStream.shouldPause(buffered: HTTPRangeStream.pauseAbove))
    XCTAssertTrue(HTTPRangeStream.shouldResume(buffered: HTTPRangeStream.resumeBelow - 1))
    XCTAssertFalse(HTTPRangeStream.shouldResume(buffered: HTTPRangeStream.resumeBelow))
    XCTAssertLessThan(HTTPRangeStream.resumeBelow, HTTPRangeStream.pauseAbove)
  }

  /// A reader that stops reading holds the transfer back once the buffer
  /// passes its limit, and reading it down lets the transfer go on — once
  /// each, not before the buffer is low.
  func testAFullBufferHoldsTheTransferBackUntilReadDown() async throws {
    let body = content(HTTPRangeStream.pauseAbove + (1 << 20))
    let (session, url) = stubbed("held", .init(content: body))
    let pacing = PacingLog()
    let stream = HTTPRangeStream(url: url, offset: 0, session: session, pacing: pacing.pacing)
    addTeardownBlock { stream.cancel() }

    try await within(5) {
      while pacing.counts.holds == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
    }
    var received = try await Self.take(1 << 20, from: stream)
    XCTAssertEqual(pacing.counts.holds, 1)
    XCTAssertEqual(pacing.counts.releases, 0, "still more than the low mark buffered")

    received.append(try await Self.take(body.count - received.count, from: stream))
    XCTAssertEqual(received, body)
    XCTAssertEqual(pacing.counts.holds, 1)
    XCTAssertEqual(pacing.counts.releases, 1)
  }

  private static func take(_ count: Int, from stream: HTTPRangeStream) async throws -> Data {
    var data = Data()
    while data.count < count {
      guard case .data(let piece) = await stream.read(maxLength: count - data.count) else {
        throw TimedOut()
      }
      data.append(piece)
    }
    return data
  }

  /// The whole stack a host builds for a network film — memory, then disk,
  /// then HTTP — hands on the first bytes without waiting for a block.
  func testTheReadingStackHandsOnWhatHasArrived() async throws {
    let body = content(3 << 20)
    let (http, _) = serving("stack", .init(content: body, withheld: 131_072..<body.count))
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("StreamingReadTests-\(UUID().uuidString)")
    let cache = try UmbelDiskCache(directory: folder, capacity: 50 << 20)
    addTeardownBlock {
      await cache.close()
      try? FileManager.default.removeItem(at: folder)
    }
    let stack = UmbelBufferedSource(
      wrapping: UmbelDiskCacheSource(wrapping: http, key: "film", cache: cache))
    let data = try await within(3) { try await stack.read(offset: 0, maxLength: 65_536) }
    XCTAssertEqual(data, body.prefix(data.count))
    XCTAssertGreaterThan(data.count, 0)
  }

  /// Opening a film needs its header and first packets, not a whole block:
  /// here the server gives the first 128 KiB and the last 32 KiB of a 300 KB
  /// file and holds the rest, and opening completes. Probing is kept to half
  /// a second of content; by default it would read this short file to its
  /// end.
  func testOpeningNeedsOnlyTheBytesItReads() async throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("styled_subs.mkv")
    let body = try Data(contentsOf: fixture)
    let (http, _) = serving(
      "open", .init(content: body, withheld: 131_072..<(body.count - 32_768)))
    let demux = DemuxSession(
      source: UmbelBufferedSource(wrapping: http),
      configuration: DemuxConfiguration(analyzeDuration: 0.5))
    addTeardownBlock { await demux.close() }
    try await within(5) { try await demux.open() }
    let tracks = await demux.tracks
    XCTAssertFalse(tracks.isEmpty)
  }
}
