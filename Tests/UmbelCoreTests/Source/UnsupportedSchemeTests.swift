import XCTest
@testable import UmbelCore

/// Serves a scheme of its own, as a session given to a source can.
private final class OwnSchemeProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "vault" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
          let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "4"]) else { return }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data([1, 2, 3, 4]))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Answers a web address with a redirect to one the session cannot read.
private final class RedirectsAwayProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url,
          let target = URL(string: "rtmp://example.invalid/live/stream"),
          let response = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]) else { return }
    client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// A host's own source, passing on the error its networking gave it.
private struct FailingSource: UmbelStreamingSource {
  let error: URLError

  var contentLength: Int64? { nil }
  func readNext(maxLength: Int) async throws -> Data { throw error }
  func invalidate() async {}
}

final class UnsupportedSchemeTests: XCTestCase {
  private func plainSession() -> URLSession { URLSession(configuration: .ephemeral) }

  private func session(with stub: URLProtocol.Type) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [stub]
    return URLSession(configuration: configuration)
  }

  private func address(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

  private func readError(_ source: UmbelHTTPSource) async -> Error? {
    do {
      _ = try await source.read(offset: 0, maxLength: 16)
      return nil
    } catch {
      return error
    }
  }

  func testAnHTTPSourceNamesTheSchemeItCannotRead() async throws {
    let cases = [
      ("rtmp://127.0.0.1/live/stream?token=secret", "rtmp"),
      ("RTMP://127.0.0.1/live/stream", "rtmp"),
      ("rtsp://127.0.0.1/stream", "rtsp"),
      ("udp://127.0.0.1:1234", "udp"),
    ]
    for (text, scheme) in cases {
      let source = UmbelHTTPSource(url: try address(text), session: plainSession())
      let error = await readError(source)
      XCTAssertEqual(error as? UmbelError, .unsupportedScheme(scheme), text)
    }
  }

  /// The source is not to spend its retries on what can never succeed, and
  /// a caller is not to be told that retrying is worthwhile.
  func testAnUnreadableSchemeIsNotRetried() async throws {
    let source = UmbelHTTPSource(url: try address("rtmp://127.0.0.1/live/stream"), session: plainSession())
    let error = await readError(source)
    XCTAssertEqual((error as? UmbelError)?.isRetryable, false)
    let failure = await source.lastFailure
    XCTAssertEqual(failure?.attempts, 1)
    XCTAssertEqual(failure?.urlErrorCode, .unsupportedURL)
  }

  /// The system answers an address with no scheme the same way; there is no
  /// scheme to name.
  func testAnAddressWithNoSchemeIsNotASchemeProblem() async throws {
    let source = UmbelHTTPSource(url: try address("foo/bar"), session: plainSession())
    let error = await readError(source)
    XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "NSURLErrorDomain error -1002"))
  }

  /// Whether a scheme can be read is the session's to say, not a list's here.
  func testASessionServingItsOwnSchemeIsStillRead() async throws {
    let source = UmbelHTTPSource(url: try address("vault://shelf/film"), session: session(with: OwnSchemeProtocol.self))
    let data = try await source.read(offset: 0, maxLength: 4)
    XCTAssertEqual(data, Data([1, 2, 3, 4]))
  }

  /// What was asked for is a web address; what cannot be read is where it led.
  func testARedirectToAnotherSchemeNamesThatScheme() async throws {
    let source = UmbelHTTPSource(
      url: try address("https://example.invalid/short"), session: session(with: RedirectsAwayProtocol.self))
    let error = await readError(source)
    XCTAssertEqual(error as? UmbelError, .unsupportedScheme("rtmp"))
  }

  func testASessionOverAnHTTPSourceFailsNamingTheScheme() async throws {
    let source = UmbelHTTPSource(url: try address("rtmp://127.0.0.1/live/stream"), session: plainSession())
    let session = PlaybackSession(source: source)
    addTeardownBlock { await session.stop() }
    do {
      try await session.load()
      XCTFail("nothing here reads this address")
    } catch {
      XCTAssertEqual(error as? UmbelError, .unsupportedScheme("rtmp"))
    }
    let reason = await session.failureReason
    XCTAssertEqual(reason, .unsupportedScheme("rtmp"))
  }

  func testASessionFoldsTheSystemsRefusalFromAHostsSource() async throws {
    let refused = URLError(
      .unsupportedURL, userInfo: [NSURLErrorFailingURLErrorKey: try address("rtmp://127.0.0.1/live/stream")])
    let session = PlaybackSession(source: FailingSource(error: refused))
    addTeardownBlock { await session.stop() }
    do {
      try await session.load()
      XCTFail("the source only fails")
    } catch {}
    let reason = await session.failureReason
    XCTAssertEqual(reason, .unsupportedScheme("rtmp"))
  }

  /// With no address to read a scheme from, or a web one, nothing says the
  /// scheme is why.
  func testTheSystemsRefusalStaysASourceFailureWhenNotAboutAScheme() throws {
    let refusals = [
      URLError(.unsupportedURL),
      URLError(.unsupportedURL, userInfo: [NSURLErrorFailingURLErrorKey: try address("https://example.invalid/x")]),
    ]
    for refusal in refusals {
      XCTAssertEqual(UmbelError.wrapping(refusal), .sourceUnavailable(detail: "NSURLErrorDomain error -1002"))
    }
  }

  /// Any other error of the system's is not a refusal, whatever its address.
  func testOtherSystemErrorsStaySourceFailures() throws {
    let timedOut = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: try address("rtmp://example.invalid/x")])
    XCTAssertEqual(UmbelError.wrapping(timedOut), .sourceUnavailable(detail: "NSURLErrorDomain error -1001"))
  }
}
