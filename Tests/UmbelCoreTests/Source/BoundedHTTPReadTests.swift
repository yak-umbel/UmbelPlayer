import Foundation
import XCTest
@testable import UmbelCore

private final class BoundedRangeProtocol: URLProtocol {
  struct Reply {
    var status: Int
    var headers: [String: String]
    var body: Data
    var failure: URLError.Code? = nil
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [URL: @Sendable (String) -> Reply] = [:]
  nonisolated(unsafe) private static var requests: [URL: [String]] = [:]

  static func serve(_ url: URL, with handler: @escaping @Sendable (String) -> Reply) {
    lock.lock(); defer { lock.unlock() }
    handlers[url] = handler
    requests[url] = []
  }

  static func ranges(for url: URL) -> [String] {
    lock.lock(); defer { lock.unlock() }
    return requests[url] ?? []
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    let range = request.value(forHTTPHeaderField: "Range") ?? ""
    Self.lock.lock()
    Self.requests[url, default: []].append(range)
    let handler = Self.handlers[url]
    Self.lock.unlock()
    guard let reply = handler?(range) else { return }
    let response = HTTPURLResponse(
      url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
    if let failure = reply.failure {
      client?.urlProtocol(self, didFailWithError: URLError(failure))
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

final class BoundedHTTPReadTests: XCTestCase {
  private func source(
    _ name: String, maximumRangeLength: Int = 4,
    retryPolicy: UmbelHTTPSource.RetryPolicy = .init(maxRetries: 2, initialDelay: 0, jitter: 0),
    handler: @escaping @Sendable (String) -> BoundedRangeProtocol.Reply
  ) -> (UmbelHTTPSource, URL) {
    let url = URL(string: "https://example.invalid/\(name)-\(UUID().uuidString)")!
    BoundedRangeProtocol.serve(url, with: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BoundedRangeProtocol.self]
    let session = URLSession(configuration: configuration)
    return (UmbelHTTPSource(
      url: url, session: session,
      retryPolicy: retryPolicy,
      maximumRangeLength: maximumRangeLength), url)
  }

  private static func bytes(_ range: String) -> BoundedRangeProtocol.Reply {
    let payload = Data((0..<10).map(UInt8.init))
    let numbers = range.dropFirst("bytes=".count).split(separator: "-")
    let start = Int(numbers[0])!
    let end = min(Int(numbers[1])!, payload.count - 1)
    if start >= payload.count {
      return .init(status: 416, headers: ["Content-Range": "bytes */10"], body: Data())
    }
    return .init(status: 206, headers: [
      "Content-Range": "bytes \(start)-\(end)/10",
      "Content-Length": "\(end - start + 1)",
    ], body: payload.subdata(in: start..<(end + 1)))
  }

  func testFiniteRangesContinueOnlyOnReadDemand() async throws {
    let (source, url) = source("finite", handler: Self.bytes)
    let first = try await source.read(offset: 0, maxLength: 20)
    XCTAssertEqual(Array(first), [0, 1, 2, 3])
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3"])
    let second = try await source.read(offset: 4, maxLength: 20)
    XCTAssertEqual(Array(second), [4, 5, 6, 7])
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3", "bytes=4-7"])
    let last = try await source.read(offset: 8, maxLength: 20)
    XCTAssertEqual(Array(last), [8, 9])
    let pastEnd = try await source.read(offset: 10, maxLength: 20)
    XCTAssertTrue(pastEnd.isEmpty)
    let totals = await source.transferStatistics
    XCTAssertEqual(totals.requestCount, 3)
    XCTAssertEqual(totals.receivedBytes, 10)
    XCTAssertEqual(totals.deliveredBytes, 10)
    XCTAssertEqual(totals.bufferedBytes, 0)
  }

  func testIgnoredFiniteRangeIsRejectedAtZero() async throws {
    let (source, _) = source("ignored") { _ in
      .init(status: 200, headers: ["Content-Length": "4"], body: Data([0, 1, 2, 3]))
    }
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("finite ranges require 206")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
  }

  func testWrongContentRangeIsRejected() async throws {
    let (source, _) = source("wrong") { _ in
      .init(status: 206, headers: ["Content-Range": "bytes 1-4/10", "Content-Length": "4"],
            body: Data([1, 2, 3, 4]))
    }
    let length = await source.contentLength
    XCTAssertNil(length, "an invalid response cannot publish its claimed total")
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("misplaced bytes must not be delivered")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
  }

  func testExcessiveOrInconsistentRangeIsRejected() async throws {
    for (name, header, length) in [
      ("excess", "bytes 0-5/10", "6"),
      ("length", "bytes 0-3/10", "3"),
      ("total", "bytes 0-3/3", "4"),
      ("syntax", "bytes nonsense", "4"),
    ] {
      let (source, _) = source(name) { _ in
        .init(status: 206, headers: ["Content-Range": header, "Content-Length": length],
              body: Data([0, 1, 2, 3]))
      }
      do {
        _ = try await source.read(offset: 0, maxLength: 4)
        XCTFail("\(name) must be refused")
      } catch let error as UmbelError {
        guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testUnknownTotalEndsOnlyAfter416() async throws {
    let (source, url) = source("unknown") { range in
      switch range {
      case "bytes=0-3":
        return .init(status: 206, headers: [
          "Content-Range": "bytes 0-1/*", "Content-Length": "2"], body: Data([0, 1]))
      case "bytes=2-5":
        return .init(status: 416, headers: ["Content-Range": "bytes */2"], body: Data())
      default:
        return .init(status: 500, headers: [:], body: Data())
      }
    }
    let first = try await source.read(offset: 0, maxLength: 8)
    XCTAssertEqual(Array(first), [0, 1])
    let pastEnd = try await source.read(offset: 2, maxLength: 8)
    XCTAssertTrue(pastEnd.isEmpty)
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3", "bytes=2-5"])
    let length = await source.contentLength
    XCTAssertEqual(length, 2)
  }

  func test416BeforeKnownEndIsAnError() async throws {
    let (source, _) = source("early-416") { _ in
      .init(status: 416, headers: ["Content-Range": "bytes */10"], body: Data())
    }
    do {
      _ = try await source.read(offset: 0, maxLength: 4)
      XCTFail("an in-range 416 is inconsistent")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
  }

  func testUnknownTotal416CannotClaimEOFAfterKnownLength() async throws {
    let (source, url) = source("unknown-416") { range in
      if range == "bytes=0-3" {
        return .init(status: 206, headers: ["Content-Range": "bytes 0-3/100",
                                            "Content-Length": "4"], body: Data([0, 1, 2, 3]))
      }
      return .init(status: 416, headers: ["Content-Range": "bytes */*"], body: Data())
    }
    _ = try await source.read(offset: 0, maxLength: 4)
    do {
      _ = try await source.read(offset: 4, maxLength: 4)
      XCTFail("416 without a complete length cannot establish EOF")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3", "bytes=4-7"])
  }

  func testInvalidationInterruptsRetryBackoffPromptly() async throws {
    let (source, url) = source(
      "retry-wait", retryPolicy: .init(maxRetries: 2, initialDelay: 30, jitter: 0)
    ) { _ in
      .init(status: 503, headers: [:], body: Data())
    }
    let reading = Task { try await source.read(offset: 0, maxLength: 4) }
    defer { reading.cancel() }
    for _ in 0..<100 where BoundedRangeProtocol.ranges(for: url).isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3"])
    try await Task.sleep(nanoseconds: 30_000_000)
    await source.invalidate()
    let finished = expectation(description: "retry wait interrupted by invalidation")
    Task {
      let result = await reading.result
      XCTAssertThrowsError(try result.get()) { error in
        XCTAssertEqual(error as? UmbelError, .interrupted)
      }
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 2)
  }

  func testLargeOffsetClampsRangeEndWithoutOverflow() async throws {
    let (source, url) = source("large", maximumRangeLength: Int.max) { _ in
      .init(status: 416, headers: ["Content-Range": "bytes */9223372036854775806"],
            body: Data())
    }
    let result = try await source.read(offset: Int64.max - 1, maxLength: 1)
    XCTAssertTrue(result.isEmpty)
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url),
                   ["bytes=9223372036854775806-9223372036854775807"])
  }

  func testChangedTotalAcrossRangesIsRejected() async throws {
    let (source, _) = source("changed") { range in
      if range == "bytes=0-3" {
        return .init(status: 206, headers: ["Content-Range": "bytes 0-3/10",
                                            "Content-Length": "4"], body: Data([0, 1, 2, 3]))
      }
      return .init(status: 206, headers: ["Content-Range": "bytes 4-7/12",
                                          "Content-Length": "4"], body: Data([4, 5, 6, 7]))
    }
    _ = try await source.read(offset: 0, maxLength: 4)
    do {
      _ = try await source.read(offset: 4, maxLength: 4)
      XCTFail("a changed length must not be silently accepted")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
  }

  func testShortCompletedBodyRetriesFromDeliveredOffset() async throws {
    let (source, url) = source("short-body") { range in
      if range == "bytes=0-3" {
        return .init(status: 206, headers: ["Content-Range": "bytes 0-3/6",
                                            "Content-Length": "4"], body: Data([0, 1]))
      }
      return .init(status: 206, headers: ["Content-Range": "bytes 2-5/6",
                                          "Content-Length": "4"], body: Data([2, 3, 4, 5]))
    }
    let first = try await source.read(offset: 0, maxLength: 6)
    XCTAssertEqual(Array(first), [0, 1])
    let rest = try await source.read(offset: 2, maxLength: 6)
    XCTAssertEqual(Array(rest), [2, 3, 4, 5])
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3", "bytes=2-5"])
  }

  func testSeekAndInvalidateKeepCumulativeStatistics() async throws {
    let (source, url) = source("seek", handler: Self.bytes)
    let first = try await source.read(offset: 0, maxLength: 2)
    XCTAssertEqual(Array(first), [0, 1])
    let partial = await source.transferStatistics
    XCTAssertEqual(partial.bufferedBytes, 2)
    XCTAssertEqual(partial.deliveredBytes, 2)
    let second = try await source.read(offset: 8, maxLength: 2)
    XCTAssertEqual(Array(second), [8, 9])
    await source.invalidate()
    let totals = await source.transferStatistics
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=0-3", "bytes=8-11"])
    XCTAssertEqual(totals.requestCount, 2)
    XCTAssertEqual(totals.receivedBytes, 6)
    XCTAssertEqual(totals.deliveredBytes, 4)
    XCTAssertEqual(totals.bufferedBytes, 0)
  }

  func testChildSourceInheritsFinitePolicy() async throws {
    let (source, url) = source("child", handler: Self.bytes)
    let child = await source.source(for: url)
    let data = try await child.read(offset: 4, maxLength: 4)
    XCTAssertEqual(Array(data), [4, 5, 6, 7])
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), ["bytes=4-7"])
  }


  func testInvalidMaximumRangeLengthMakesNoRequest() async throws {
    let (source, url) = source("invalid", maximumRangeLength: 0, handler: Self.bytes)
    do {
      _ = try await source.read(offset: 0, maxLength: 1)
      XCTFail("zero is invalid configuration")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(BoundedRangeProtocol.ranges(for: url), [])
  }
}
