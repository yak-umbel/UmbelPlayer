import Foundation
import XCTest
import UmbelCore

final class HTTPTransportTests: XCTestCase {
  private struct DeadlineExceeded: Error {}

  private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
      self.continuation = continuation
    }

    @discardableResult
    func resolve(_ result: Result<Data, Error>) -> Bool {
      lock.lock()
      let pending = continuation
      continuation = nil
      lock.unlock()
      pending?.resume(with: result)
      return pending != nil
    }
  }

  private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 10
    return URLSession(configuration: configuration)
  }

  private func source(
    at url: URL, session: URLSession, maximumRangeLength: Int? = 4096
  ) -> UmbelHTTPSource {
    UmbelHTTPSource(
      url: url, session: session,
      retryPolicy: .init(maxRetries: 2, initialDelay: 0.01, jitter: 0),
      maximumRangeLength: maximumRangeLength)
  }

  /// A timeout invalidates the source so a broken waiting read does not hold
  /// the test process open. The operation completes the continuation once.
  private func within(
    _ source: any UmbelSource, seconds: UInt64 = 3,
    operation: @escaping @Sendable () async throws -> Data
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let completion = Completion(continuation)
      let operationTask = Task {
        do { completion.resolve(.success(try await operation())) }
        catch { completion.resolve(.failure(error)) }
      }
      Task {
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        if completion.resolve(.failure(DeadlineExceeded())) {
          operationTask.cancel()
          await source.invalidate()
        }
      }
    }
  }

  private func waitUntil(
    seconds: UInt64 = 3, _ predicate: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while !predicate() {
      guard Date() < deadline else { throw DeadlineExceeded() }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func readAll(
    from source: UmbelHTTPSource, length: Int, initial: Data = Data()
  ) async throws -> Data {
    var result = initial
    while result.count < length {
      let offset = Int64(result.count)
      let piece = try await within(source) {
        try await source.read(offset: offset, maxLength: 2048)
      }
      guard !piece.isEmpty else { break }
      result.append(piece)
    }
    return result
  }

  private func assertGeneratedBytes(
    _ data: Data, from offset: Int = 0, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(data, Data((offset..<(offset + data.count)).map(HTTPTransportTestServer.byte(at:))),
                   file: file, line: line)
  }

  func testFiniteStoppedConsumerDoesNotRequestAnotherRangeAndOpenDefaultRemainsOpen() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 32_768)
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let finite = source(at: server.url(path: "finite"), session: client)
    let first = try await within(finite) { try await finite.read(offset: 0, maxLength: 512) }
    XCTAssertFalse(first.isEmpty)
    assertGeneratedBytes(first)
    try await waitUntil { server.snapshot().completedBodyWrites >= 4096 }
    try await Task.sleep(nanoseconds: 100_000_000)
    let stopped = server.snapshot()
    XCTAssertEqual(stopped.requests.filter { $0.path == "/finite" }.map(\.range),
                   ["bytes=0-4095"])
    XCTAssertEqual(stopped.completedBodyWrites, 4096)
    let finiteAtStop = await finite.transferStatistics
    XCTAssertEqual(finiteAtStop.requestCount, 1)
    XCTAssertEqual(finiteAtStop.deliveredBytes, Int64(first.count))
    XCTAssertLessThanOrEqual(finiteAtStop.receivedBytes, 4096)

    let open = source(at: server.url(path: "open"), session: client, maximumRangeLength: nil)
    let openFirst = try await within(open) { try await open.read(offset: 0, maxLength: 512) }
    assertGeneratedBytes(openFirst)
    try await waitUntil { server.snapshot().completedBodyWrites >= 4096 + 32_768 }
    let sample = server.snapshot()
    XCTAssertEqual(sample.requests.filter { $0.path == "/open" }.map(\.range), ["bytes=0-"])

    let complete = try await readAll(from: finite, length: 32_768, initial: first)
    XCTAssertEqual(complete.count, 32_768)
    assertGeneratedBytes(complete)
    let eof = try await within(finite) { try await finite.read(offset: 32_768, maxLength: 8) }
    XCTAssertTrue(eof.isEmpty)
    XCTAssertEqual(server.snapshot().requests.filter { $0.path == "/finite" }.map(\.range),
                   (0..<8).map { "bytes=\($0 * 4096)-\($0 * 4096 + 4095)" })
    let finiteConnections = Set(server.snapshot().requests.filter { $0.path == "/finite" }
      .map(\.connectionID))
    print("HTTP finite sequential ranges used \(finiteConnections.count) connection(s)")
    let totals = await finite.transferStatistics
    XCTAssertEqual(totals.deliveredBytes, 32_768)
    XCTAssertEqual(totals.receivedBytes, 32_768)
    XCTAssertEqual(totals.bufferedBytes, 0)
    await finite.invalidate()
    await open.invalidate()
  }

  func testMegabyteBoundedStopComparedWithOpenRequest() async throws {
    let oneMiB = 1 << 20
    let server = try HTTPTransportTestServer(bodyLength: 9 << 20)
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let finite = source(at: server.url(path: "finite-large"), session: client,
                        maximumRangeLength: oneMiB)
    let finiteFirst = try await within(finite) {
      try await finite.read(offset: 0, maxLength: 64 << 10)
    }
    XCTAssertFalse(finiteFirst.isEmpty)
    assertGeneratedBytes(finiteFirst)
    try await waitUntil(seconds: 5) {
      server.snapshot().completedBodyWrites >= Int64(oneMiB)
    }
    try await Task.sleep(nanoseconds: 250_000_000)
    let finiteStop = server.snapshot()
    let finiteStats = await finite.transferStatistics
    XCTAssertEqual(finiteStop.requests.filter { $0.path == "/finite-large" }.map(\.range),
                   ["bytes=0-1048575"])
    XCTAssertEqual(finiteStop.completedBodyWrites, Int64(oneMiB))
    XCTAssertLessThanOrEqual(finiteStats.receivedBytes, Int64(oneMiB))
    XCTAssertEqual(finiteStats.deliveredBytes, Int64(finiteFirst.count))

    let open = source(at: server.url(path: "open-large"), session: client,
                      maximumRangeLength: nil)
    let openFirst = try await within(open) {
      try await open.read(offset: 0, maxLength: 64 << 10)
    }
    XCTAssertFalse(openFirst.isEmpty)
    assertGeneratedBytes(openFirst)
    try await Task.sleep(nanoseconds: 250_000_000)
    let openStop = server.snapshot()
    let openStats = await open.transferStatistics
    XCTAssertEqual(openStop.requests.filter { $0.path == "/open-large" }.map(\.range),
                   ["bytes=0-"])
    print("HTTP transport stopped 1MiB finite: serverWritten=\(finiteStop.completedBodyWrites) received=\(finiteStats.receivedBytes) delivered=\(finiteStats.deliveredBytes) buffered=\(finiteStats.bufferedBytes); open: serverWritten=\(openStop.completedBodyWrites - finiteStop.completedBodyWrites) received=\(openStats.receivedBytes) delivered=\(openStats.deliveredBytes) buffered=\(openStats.bufferedBytes)")
    await finite.invalidate()
    await open.invalidate()
  }

  func testPartialBodyReturnsBeforePausedRangeCompletes() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 16_384, behavior: .pause(after: 1024))
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let input = source(at: server.url, session: client, maximumRangeLength: 8192)
    let first = try await within(input) { try await input.read(offset: 0, maxLength: 4096) }
    XCTAssertFalse(first.isEmpty)
    XCTAssertLessThanOrEqual(first.count, 1024)
    assertGeneratedBytes(first)
    try await waitUntil { server.snapshot().completedBodyWrites == 1024 }
    XCTAssertEqual(server.snapshot().requests.map(\.range), ["bytes=0-8191"])
    server.releasePausedResponses()
    let secondOffset = Int64(first.count)
    let second = try await within(input) {
      try await input.read(offset: secondOffset, maxLength: 4096)
    }
    XCTAssertFalse(second.isEmpty)
    assertGeneratedBytes(second, from: first.count)
    await input.invalidate()
  }

  func testSeekCancelsPausedOldRangeAndReadsAtNewOffset() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 32_768, behavior: .pause(after: 1024))
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let input = source(at: server.url, session: client, maximumRangeLength: 8192)
    let prefix = try await within(input) { try await input.read(offset: 0, maxLength: 512) }
    assertGeneratedBytes(prefix)
    let sought = try await within(input) { try await input.read(offset: 16_384, maxLength: 512) }
    XCTAssertFalse(sought.isEmpty)
    assertGeneratedBytes(sought, from: 16_384)
    XCTAssertEqual(server.snapshot().requests.map(\.range),
                   ["bytes=0-8191", "bytes=16384-24575"])
    try await waitUntil { server.snapshot().closedRanges.contains("bytes=0-8191") }
    await input.invalidate()
  }

  func testCancellingWaitingReadAndInvalidatingSourceWakeCallers() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 8192, behavior: .pause(after: 0))
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let cancelled = source(at: server.url(path: "cancel"), session: client)
    let waiting = Task { try await cancelled.read(offset: 0, maxLength: 512) }
    try await waitUntil { server.snapshot().requests.contains { $0.path == "/cancel" } }
    waiting.cancel()
    do {
      _ = try await within(cancelled) { try await waiting.value }
      XCTFail("cancelling a waiting read must stop it")
    } catch is DeadlineExceeded {
      XCTFail("cancelled read did not wake")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .interrupted)
    } catch {
      XCTFail("unexpected cancellation error: \(error)")
    }
    await cancelled.invalidate()

    let invalidated = source(at: server.url(path: "invalidate"), session: client)
    let second = Task { try await invalidated.read(offset: 0, maxLength: 512) }
    try await waitUntil { server.snapshot().requests.contains { $0.path == "/invalidate" } }
    await invalidated.invalidate()
    do {
      _ = try await within(invalidated) { try await second.value }
      XCTFail("invalidation must wake a waiting read")
    } catch is DeadlineExceeded {
      XCTFail("invalidated read did not wake")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .interrupted)
    } catch {
      XCTFail("unexpected invalidation error: \(error)")
    }
  }

  func testInterruptedBodyResumesAtNextUndeliveredByte() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 20_000,
                                             behavior: .interruptFirst(after: 1000))
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let input = source(at: server.url, session: client)
    let complete = try await readAll(from: input, length: 20_000)
    XCTAssertEqual(complete.count, 20_000)
    assertGeneratedBytes(complete)
    let ranges = server.snapshot().requests.map(\.range)
    XCTAssertEqual(ranges.first, "bytes=0-4095")
    // The server cut the body after 1000 bytes; how many of them reached the
    // client before the cut depends on timing — under load, none may. The
    // retry starts wherever delivery stopped.
    let bounds = ranges.dropFirst().first.map { $0.dropFirst("bytes=".count).split(separator: "-") }
    guard let bounds, bounds.count == 2, let retryStart = Int(bounds[0]), let retryEnd = Int(bounds[1]) else {
      return XCTFail("no retry: \(ranges)")
    }
    XCTAssertTrue((0...1000).contains(retryStart), "at most what was sent: \(ranges)")
    XCTAssertGreaterThanOrEqual(retryEnd, retryStart)
    XCTAssertLessThanOrEqual(retryEnd - retryStart + 1, 4096)
    // Resumed at the first undelivered byte: none received twice.
    let totals = await input.transferStatistics
    XCTAssertEqual(totals.deliveredBytes, 20_000)
    XCTAssertEqual(totals.receivedBytes, 20_000)
    await input.invalidate()
  }

  /// A reader that stops for longer than the session's request timeout lets
  /// the held transfer time out: the system keeps timing a suspended task.
  /// That timeout is the source's own doing, not the network's, so reading
  /// on spends no retry — this source has none to spend.
  func testATransferHeldPastTheRequestTimeoutReadsOnWithoutARetry() async throws {
    let length = 8 << 20
    let server = try HTTPTransportTestServer(bodyLength: length)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 1
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel(); server.stop() }
    let input = UmbelHTTPSource(url: server.url, session: client,
                                retryPolicy: .init(maxRetries: 0, initialDelay: 0, jitter: 0))
    var received = try await within(input) { try await input.read(offset: 0, maxLength: 2048) }
    // Past four mebibytes unread, the transfer is held back.
    let deadline = Date().addingTimeInterval(3)
    while await input.transferStatistics.bufferedBytes <= 4 << 20 {
      guard Date() < deadline else { throw DeadlineExceeded() }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await Task.sleep(nanoseconds: 2_500_000_000)
    while received.count < length {
      let offset = Int64(received.count)
      let piece = try await within(input) {
        try await input.read(offset: offset, maxLength: 1 << 20)
      }
      guard !piece.isEmpty else { break }
      received.append(piece)
    }
    XCTAssertEqual(received.count, length)
    assertGeneratedBytes(received)
    let ranges = server.snapshot().requests.map(\.range)
    XCTAssertEqual(ranges.count, 2, "the held request timed out and one more read on: \(ranges)")
    XCTAssertEqual(ranges.first, "bytes=0-")
    await input.invalidate()
  }

  /// The detail names the networking error by its code, not by the system's
  /// words for it, which follow the device's language. A stubbed error has
  /// no such words; the system's own timeout does.
  func testATimeoutNamesItsCode() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 4096, behavior: .pause(after: 0))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 1
    let client = URLSession(configuration: configuration)
    defer { client.invalidateAndCancel(); server.stop() }
    let input = UmbelHTTPSource(url: server.url, session: client,
                                retryPolicy: .init(maxRetries: 0, initialDelay: 0, jitter: 0))
    do {
      _ = try await within(input) { try await input.read(offset: 0, maxLength: 256) }
      XCTFail("a response that never comes must surface")
    } catch let error as UmbelError {
      guard case .sourceUnavailable(let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("-1001"), detail)
    }
    await input.invalidate()
  }

  func testReplacementSourceRetainsFinitePolicyAndSurvivesOriginalInvalidation() async throws {
    let server = try HTTPTransportTestServer(bodyLength: 16_384)
    let client = session()
    defer { client.invalidateAndCancel(); server.stop() }
    let original = source(at: server.url(path: "original"), session: client)
    let replacement = await original.source(for: server.url(path: "replacement"))
    let first = try await within(original) { try await original.read(offset: 0, maxLength: 256) }
    assertGeneratedBytes(first)
    await original.invalidate()
    let child = try await within(replacement) {
      try await replacement.read(offset: 4096, maxLength: 256)
    }
    XCTAssertFalse(child.isEmpty)
    assertGeneratedBytes(child, from: 4096)
    XCTAssertEqual(server.snapshot().requests.filter { $0.path == "/replacement" }.map(\.range),
                   ["bytes=4096-8191"])
    await replacement.invalidate()
  }
}
