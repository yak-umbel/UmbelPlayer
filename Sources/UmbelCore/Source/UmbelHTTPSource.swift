import Foundation

/// Random access over HTTP ranges.
///
/// Reads are streamed: one connection is opened where reading starts and
/// read on in order, each read handing over whatever has arrived, and only a
/// read elsewhere opens another. Opening a film needs a few hundred
/// kilobytes; requesting a block per read and waiting for all of it held up
/// the first byte by the block's download time — a second, for a mebibyte
/// on a slow link. The same offset still gives the same bytes: streaming is
/// how reads are made, not what they return.
public actor UmbelHTTPSource: UmbelLocatedSource {
  /// How transient failures are retried.
  ///
  /// Bounded exponential backoff with jitter, the shape most HTTP clients
  /// settle on. Bounded, because a player that retries forever never tells the
  /// host anything is wrong. Jittered, because many players retrying on the
  /// same beat hammer a server just as it comes back.
  public struct RetryPolicy: Sendable {
    public var maxRetries: Int
    /// Wait before the first retry; each later one doubles it.
    public var initialDelay: TimeInterval
    /// Each wait is spread by up to this fraction either way.
    public var jitter: Double
    /// How long a read keeps trying while the system says the device has no
    /// network — not connected, data not allowed, roaming off, a call on —
    /// spending none of `maxRetries`. Such failures come back at once while
    /// the network is away, so retries would be gone in moments, and they say
    /// nothing of the server: switching to another address would not help.
    /// A minute by default, which rides out a dropped Wi-Fi or a dead spot;
    /// what is buffered plays meanwhile, and the session shows buffering once
    /// it runs out. The waits back off as retries do, no further apart than
    /// two seconds, so reading resumes soon after the network does. Zero
    /// counts these failures as any other.
    public var offlinePatience: TimeInterval

    public init(
      maxRetries: Int = 3, initialDelay: TimeInterval = 0.25, jitter: Double = 0.2,
      offlinePatience: TimeInterval = 60
    ) {
      self.maxRetries = maxRetries
      self.initialDelay = initialDelay
      self.jitter = jitter
      self.offlinePatience = offlinePatience
    }

    /// `retry` counts from 1.
    public func delay(beforeRetry retry: Int) -> TimeInterval {
      let base = initialDelay * pow(2, Double(retry - 1))
      guard jitter > 0 else { return base }
      return base * Double.random(in: (1 - jitter)...(1 + jitter))
    }
  }

  private let url: URL
  private let headers: [String: String]
  private let lane: HTTPSessionLane
  private let retryPolicy: RetryPolicy
  private let maximumRangeLength: Int?
  private let meter = HTTPTransferMeter()
  private var cachedLength: Int64?
  private var isInvalidated = false
  private var retryWaits: [UUID: Task<Void, Error>] = [:]
  /// The connection being read in order; see `HTTPRangeStream`.
  private var stream: HTTPRangeStream?
  /// Where reads have found the content; nil until one is answered.
  private var foundAt: URL?

  /// `headers` go with every request: the Referer, User-Agent or cookies a
  /// site wants.
  ///
  /// After a request times out, later ones go out on a fresh session: a
  /// timed-out request can leave its connection open but silent in the
  /// session's pool, where the next request would land again. `makeSession`
  /// makes that session — a new one each call, set up like `session`; the
  /// source invalidates it once replaced or no longer used. Without it, a
  /// session with no delegate is renewed from its configuration, and one with
  /// a delegate is kept, since what its delegate decides cannot be carried
  /// over. `session` itself is never invalidated. Sources opened with
  /// `source(for:)` share the renewal.
  public init(
    url: URL, headers: [String: String] = [:], session: URLSession = .shared,
    retryPolicy: RetryPolicy = .init(), maximumRangeLength: Int? = nil,
    makeSession: (@Sendable () -> URLSession)? = nil
  ) {
    self.init(url: url, headers: headers,
              lane: HTTPSessionLane(session: session, makeSession: makeSession),
              retryPolicy: retryPolicy, maximumRangeLength: maximumRangeLength)
  }

  private init(
    url: URL, headers: [String: String], lane: HTTPSessionLane,
    retryPolicy: RetryPolicy, maximumRangeLength: Int?
  ) {
    self.url = url
    self.headers = headers
    self.lane = lane
    self.retryPolicy = retryPolicy
    self.maximumRangeLength = maximumRangeLength
  }

  /// A cumulative snapshot for this source, retained after invalidation.
  public var transferStatistics: HTTPTransferStatistics { meter.snapshot }

  /// The last request that failed, whether or not a retry got past it; nil
  /// while none has. Retained after invalidation. A read cut short by
  /// cancellation or invalidation is no failure.
  public private(set) var lastFailure: HTTPRequestFailure?

  /// Where the content was found: after any redirects once a read has been
  /// answered, the address asked for before that. Relative addresses in the
  /// content resolve against it.
  public var location: URL { foundAt ?? url }

  public func source(for url: URL) -> any UmbelRandomAccessSource {
    UmbelHTTPSource(url: url, headers: headers, lane: lane,
                    retryPolicy: retryPolicy, maximumRangeLength: maximumRangeLength)
  }

  /// From the first response: on the connection reading goes on, or one
  /// opened at the start for the first read to use. No request of its own —
  /// and no HEAD, which some servers and local proxies answer wrongly.
  public var contentLength: Int64? {
    get async {
      if let cachedLength { return cachedLength }
      guard !isInvalidated else { return nil }
      if let maximumRangeLength, maximumRangeLength <= 0 { return nil }
      let stream = self.stream ?? self.stream(at: 0)
      guard let length = await stream.totalLength() else { return nil }
      if foundAt == nil { foundAt = stream.responseURL }
      cachedLength = length
      return length
    }
  }

  public func read(offset: Int64, maxLength: Int) async throws -> Data {
    guard !isInvalidated else { throw UmbelError.interrupted }
    guard !Task.isCancelled else { throw UmbelError.interrupted }
    if let maximumRangeLength, maximumRangeLength <= 0 {
      throw UmbelError.sourceUnavailable(detail: "maximumRangeLength must be positive")
    }
    guard offset >= 0, maxLength > 0 else { return Data() }

    var retry = 0
    var offlineWaits = 0
    var offlineSince: TimeInterval?
    while true {
      let stream = self.stream(at: offset)
      let piece = await withTaskCancellationHandler {
        await stream.read(maxLength: maxLength)
      } onCancel: {
        stream.cancel()
      }
      guard !Task.isCancelled, !isInvalidated else {
        stream.cancel()
        if self.stream === stream { self.stream = nil }
        throw UmbelError.interrupted
      }
      if let cachedLength, let reportedLength = stream.knownTotal,
         cachedLength != reportedLength {
        stream.cancel()
        if self.stream === stream { self.stream = nil }
        let error = UmbelError.sourceUnavailable(detail: "HTTP resource length changed between ranges")
        record(error, of: stream, at: offset, attempts: retry + offlineWaits + 1)
        throw error
      }
      switch piece {
      case .data(let data):
        if foundAt == nil { foundAt = stream.responseURL }
        if cachedLength == nil { cachedLength = stream.knownTotal }
        meter.delivered(data.count)
        return data
      case .rangeComplete:
        if cachedLength == nil { cachedLength = stream.knownTotal }
        if self.stream === stream { self.stream = nil }
        if let cachedLength, offset >= cachedLength { return Data() }
        if offset == Int64.max { return Data() }
        retry = 0
        continue
      case .expiredWhileHeld:
        // The reader stopped for longer than the session's request timeout;
        // the network did nothing wrong, so no retry is spent and none waited.
        if self.stream === stream { self.stream = nil }
        continue
      case .end:
        if cachedLength == nil { cachedLength = stream.knownTotal }
        return Data()
      case .failure(let error, let transient):
        if self.stream === stream { self.stream = nil }
        // Invalidated meanwhile: the host is done with this source.
        guard !isInvalidated else { throw UmbelError.interrupted }
        // Cancelled by another read moving elsewhere: no failure either.
        if error != .interrupted { record(error, of: stream, at: offset, attempts: retry + offlineWaits + 1) }
        if stream.urlErrorCode == .timedOut, lane.renew(after: stream.sessionGeneration) {
          meter.renewedSession()
        }
        if retryPolicy.offlinePatience > 0, let code = stream.urlErrorCode, Self.offline.contains(code) {
          let now = ProcessInfo.processInfo.systemUptime
          let left = (offlineSince ?? now) + retryPolicy.offlinePatience - now
          guard left > 0 else { throw error }
          if offlineSince == nil { offlineSince = now }
          offlineWaits += 1
          let delay = retryPolicy.delay(beforeRetry: offlineWaits)
          try await waitBeforeRetry(min(max(delay, Self.offlineWaitRange.lowerBound),
                                        Self.offlineWaitRange.upperBound, left))
          guard !Task.isCancelled, !isInvalidated else { throw UmbelError.interrupted }
          continue
        }
        guard transient, retry < retryPolicy.maxRetries else { throw error }
        retry += 1
        let delay = retryPolicy.delay(beforeRetry: retry)
        try await waitBeforeRetry(delay)
        guard !Task.isCancelled, !isInvalidated else { throw UmbelError.interrupted }
      }
    }
  }

  /// The system saying the device has no network, rather than anything of
  /// the server; see `RetryPolicy.offlinePatience`.
  private static let offline: Set<URLError.Code> = [
    .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
  ]

  /// Waits while offline: never so short that a policy without delays spins
  /// on requests the system refuses at once, never so long that reading lags
  /// far behind the network's return.
  private static let offlineWaitRange: ClosedRange<TimeInterval> = 0.1...2

  private func record(_ error: UmbelError, of stream: HTTPRangeStream, at offset: Int64, attempts: Int) {
    let system = stream.systemError
    lastFailure = HTTPRequestFailure(
      error: error, urlErrorCode: stream.urlErrorCode, errorDomain: system?.domain,
      errorCode: system?.code, httpStatus: stream.status, offset: offset, attempts: attempts)
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

  /// The open connection if it is where the read starts; otherwise a new
  /// one from there. Reading in order, as a demuxer mostly does, keeps to
  /// one connection; a seek opens another.
  private func stream(at offset: Int64) -> HTTPRangeStream {
    if let stream, stream.position == offset { return stream }
    stream?.cancel()
    let (session, generation) = lane.session
    let opened = HTTPRangeStream(url: url, offset: offset, session: session, headers: headers,
                                 maximumRangeLength: maximumRangeLength, meter: meter,
                                 sessionGeneration: generation)
    stream = opened
    return opened
  }

  public func invalidate() async {
    isInvalidated = true
    let waits = Array(retryWaits.values)
    retryWaits.removeAll()
    for wait in waits { wait.cancel() }
    stream?.cancel()
    stream = nil
  }
}
