import Foundation

/// A live stream over HTTP, read once and in order: HTTP-FLV, HTTP-TS, any
/// endless body.
///
/// It sends no `Range` and has no position to come back to, so unlike
/// `UmbelHTTPSource` it is a streaming source: the session reports it cannot
/// seek, and a connection that is cut is an error, not something to carry on
/// from. Whether to open the stream again is the host's to decide.
///
/// A request that fails **before the first byte** is retried a few times (a
/// 5xx, a connection that did not come up), since nothing has been
/// delivered. Once a byte has been, it never is.
public actor UmbelLiveHTTPSource: UmbelStreamingSource {
  private let url: URL
  private let headers: [String: String]
  private let session: URLSession
  private let startRetries: Int
  private let startRetryDelay: TimeInterval
  private let pacing: HTTPRangeStream.Pacing
  private var body: HTTPLiveBody?
  private var hasDelivered = false
  private var isInvalidated = false
  private var retryWaits: [UUID: Task<Void, Error>] = [:]

  /// `headers` go with the request: the Referer, User-Agent or cookies a site
  /// wants. `session` decides the rest — proxies, trust, how long a silent
  /// connection is kept — and is never invalidated here.
  /// `startRetries` counts retries before the first byte; each waits twice as
  /// long as the one before, from `startRetryDelay` seconds.
  public init(
    url: URL, headers: [String: String] = [:], session: URLSession = .shared,
    startRetries: Int = 2, startRetryDelay: TimeInterval = 0.5
  ) {
    self.init(
      url: url, headers: headers, session: session, startRetries: startRetries,
      startRetryDelay: startRetryDelay, pacing: HTTPRangeStream.Pacing())
  }

  init(
    url: URL, headers: [String: String], session: URLSession, startRetries: Int,
    startRetryDelay: TimeInterval, pacing: HTTPRangeStream.Pacing
  ) {
    self.url = url
    self.headers = headers
    self.session = session
    self.startRetries = max(0, startRetries)
    self.startRetryDelay = max(0, startRetryDelay)
    self.pacing = pacing
  }

  /// Released without being invalidated: the connection still goes.
  deinit { body?.cancel() }

  /// A live stream has no length, whatever the response says.
  public var contentLength: Int64? { nil }

  public func readNext(maxLength: Int) async throws -> Data {
    guard !isInvalidated, !Task.isCancelled else { throw UmbelError.interrupted }
    guard maxLength > 0 else { return Data() }
    var retries = 0
    while true {
      let body = self.body ?? open()
      switch await body.queue.take(maxLength: maxLength) {
      case .data(let data):
        hasDelivered = true
        return data
      case .end:
        return Data()
      case .woken:
        // Cancelled: only this read gives up, the stream goes on.
        throw UmbelError.interrupted
      case .failure(let error):
        guard !isInvalidated else { throw UmbelError.interrupted }
        guard error != .interrupted, !hasDelivered, body.isTransientFailure, retries < startRetries else {
          throw error
        }
        body.cancel()
        self.body = nil
        retries += 1
        try await waitBeforeRetry(startRetryDelay * pow(2, Double(retries - 1)))
        guard !isInvalidated, !Task.isCancelled else { throw UmbelError.interrupted }
      }
    }
  }

  public func invalidate() async {
    isInvalidated = true
    let waits = Array(retryWaits.values)
    retryWaits.removeAll()
    for wait in waits { wait.cancel() }
    body?.cancel()
  }

  private func open() -> HTTPLiveBody {
    let opened = HTTPLiveBody(url: url, session: session, headers: headers, pacing: pacing)
    body = opened
    return opened
  }

  private func waitBeforeRetry(_ delay: TimeInterval) async throws {
    let id = UUID()
    let wait = Task { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    retryWaits[id] = wait
    defer { retryWaits[id] = nil }
    do {
      try await withTaskCancellationHandler {
        try await wait.value
      } onCancel: {
        wait.cancel()
      }
    } catch {
      throw UmbelError.interrupted
    }
  }
}
