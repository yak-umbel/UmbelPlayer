import Foundation

/// One ranged GET, read in order as it arrives: the connection beneath
/// `UmbelHTTPSource`.
///
/// It hands over available bytes without waiting for the whole response.
/// At the high watermark it suspends the URLSession task; the low watermark
/// resumes it. These thresholds apply to this delegate buffer, not to bytes
/// URLSession or the network stack may already hold.
///
/// A class with a lock rather than an actor: the session's delegate calls
/// arrive on its own queue and have to be handled there, synchronously.
final class HTTPRangeStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Piece {
    case data(Data)
    /// Nothing more: the end of the content.
    case end
    /// This finite response ended; the next request begins on read demand.
    case rangeComplete
    /// Timed out while held back for a reader that fell behind, with nothing
    /// come since: the system keeps timing a suspended task. The source's own
    /// doing, not the network's; a new request reads on.
    case expiredWhileHeld
    case failure(UmbelError, transient: Bool)
  }

  static let pauseAbove = 4 << 20
  static let resumeBelow = 1 << 20

  static func shouldPause(buffered: Int) -> Bool { buffered > pauseAbove }
  static func shouldResume(buffered: Int) -> Bool { buffered < resumeBelow }

  /// How the transfer is held back and let go on: the task's own suspend
  /// and resume. Tests watch it instead — a stubbed transfer ignores
  /// suspension, so reading on would show nothing.
  struct Pacing: Sendable {
    var hold: @Sendable (URLSessionTask) -> Void = { $0.suspend() }
    var release: @Sendable (URLSessionTask) -> Void = { $0.resume() }
  }

  private let start: Int64
  private let requestedEnd: Int64?
  /// Which of its source's sessions the request went out on.
  let sessionGeneration: Int
  private let meter: HTTPTransferMeter
  private let pacing: Pacing
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var buffer = Data()
  private var consumed: Int64 = 0
  private var receivedBody: Int64 = 0
  private var expectedBodyLength: Int64?
  /// How the transfer ended, once it has; handed over once `buffer` is read.
  private var outcome: Piece?
  private var isPaused = false
  /// Held back when the last byte came — bytes already on their way still
  /// come after a hold — so a timeout counts the hold, even once let go on.
  private var heldSinceData = false
  private var isCancelled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  /// Where the response came from: after redirects, the last address.
  private var respondedFrom: URL?
  /// The content's whole length, as the response said it; nil until it
  /// came, or when it did not say.
  private var total: Int64?
  /// A response came, or the transfer ended without one.
  private var hasResponded = false
  /// The response's status, once an HTTP one came.
  private var responseStatus: Int?
  /// The system error the transfer ended with, if that is how it ended: a
  /// networking error or one from below the URL layer.
  private var transportError: (domain: String, code: Int)?
  private var responseWaiters: [CheckedContinuation<Void, Never>] = []

  /// The host's headers, then the content as it is: no compression. Byte
  /// ranges count the bytes as sent — of a compressed response, the
  /// compressed ones — while the system's networking asks for compression by
  /// itself and hands over the bytes undone, so offsets and lengths would
  /// belong to another representation. Servers do compress playlists.
  static func apply(_ headers: [String: String], to request: inout URLRequest) {
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
  }

  init(
    url: URL, offset: Int64, session: URLSession, headers: [String: String] = [:],
    maximumRangeLength: Int? = nil, meter: HTTPTransferMeter = HTTPTransferMeter(),
    pacing: Pacing = Pacing(), sessionGeneration: Int = 0
  ) {
    start = offset
    self.sessionGeneration = sessionGeneration
    if let maximumRangeLength, maximumRangeLength > 0 {
      requestedEnd = offset + min(Int64(maximumRangeLength - 1), Int64.max - offset)
    } else {
      requestedEnd = nil
    }
    self.meter = meter
    self.pacing = pacing
    super.init()
    var request = URLRequest(url: url)
    Self.apply(headers, to: &request)
    // After the host's headers, so no header of theirs can move the range.
    let range = requestedEnd.map { "bytes=\(offset)-\($0)" } ?? "bytes=\(offset)-"
    request.setValue(range, forHTTPHeaderField: "Range")
    let task = session.dataTask(with: request)
    task.delegate = self
    self.task = task
    meter.opened()
    task.resume()
  }

  var responseURL: URL? {
    lock.lock(); defer { lock.unlock() }
    return respondedFrom
  }

  /// Where the next byte read comes from.
  var position: Int64 {
    lock.lock(); defer { lock.unlock() }
    let (position, overflow) = start.addingReportingOverflow(consumed)
    return overflow ? Int64.max : position
  }

  var knownTotal: Int64? {
    lock.lock(); defer { lock.unlock() }
    return total
  }

  var status: Int? {
    lock.lock(); defer { lock.unlock() }
    return responseStatus
  }

  var systemError: (domain: String, code: Int)? {
    lock.lock(); defer { lock.unlock() }
    return transportError
  }

  var urlErrorCode: URLError.Code? {
    guard let error = systemError, error.domain == NSURLErrorDomain else { return nil }
    return URLError.Code(rawValue: error.code)
  }

  /// Up to `maxLength` bytes of what has arrived, waiting only while nothing
  /// has.
  func read(maxLength: Int) async -> Piece {
    while true {
      if let piece = take(maxLength) { return piece }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        lock.lock()
        if buffer.isEmpty, outcome == nil, !isCancelled {
          waiters.append(continuation)
          lock.unlock()
        } else {
          lock.unlock()
          continuation.resume()
        }
      }
    }
  }

  /// The content's whole length, from the response to this request, once it
  /// has come: a range's `Content-Range`, or all of it from byte 0. Nil when
  /// the response did not say, or none came.
  func totalLength() async -> Int64? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if hasResponded || isCancelled {
        lock.unlock()
        continuation.resume()
      } else {
        responseWaiters.append(continuation)
        lock.unlock()
      }
    }
    return recordedTotal
  }

  private var recordedTotal: Int64? {
    lock.lock(); defer { lock.unlock() }
    return total
  }

  /// Stops the transfer and wakes a waiting read, which then fails as
  /// interrupted.
  func cancel() {
    lock.lock()
    guard !isCancelled else { lock.unlock(); return }
    isCancelled = true
    meter.buffered(-buffer.count)
    buffer.removeAll()
    let waiting = waiters
    waiters.removeAll()
    let task = self.task
    let wasPaused = isPaused
    isPaused = false
    lock.unlock()
    if wasPaused, let task { pacing.release(task) }
    task?.cancel()
    for continuation in waiting { continuation.resume() }
    respond(total: nil)
  }

  /// Records what the response said of the length, once, and wakes those
  /// waiting for it.
  private func respond(total length: Int64?) {
    lock.lock()
    guard !hasResponded else {
      lock.unlock()
      return
    }
    hasResponded = true
    total = length
    let waiting = responseWaiters
    responseWaiters.removeAll()
    lock.unlock()
    for continuation in waiting { continuation.resume() }
  }

  private func take(_ maxLength: Int) -> Piece? {
    lock.lock(); defer { lock.unlock() }
    if isCancelled { return .failure(.interrupted, transient: false) }
    if !buffer.isEmpty {
      let count = min(maxLength, buffer.count)
      let data = Data(buffer.prefix(count))
      buffer.removeFirst(count)
      consumed += Int64(count)
      meter.buffered(-count)
      if isPaused, Self.shouldResume(buffered: buffer.count) {
        isPaused = false
        if let task { pacing.release(task) }
      }
      return .data(data)
    }
    return outcome
  }

  /// Records how the transfer ended, unless it already has, and wakes a
  /// waiting read.
  private func finish(_ piece: Piece) {
    lock.lock()
    if outcome == nil { outcome = piece }
    let waiting = waiters
    waiters.removeAll()
    lock.unlock()
    for continuation in waiting { continuation.resume() }
  }

  // ── The session's delegate calls ────────────────────

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    respondedFrom = response.url
    responseStatus = (response as? HTTPURLResponse)?.statusCode
    lock.unlock()
    let validation = requestedEnd.map {
      HTTPRangeResponse.validate(response, start: start, requestedEnd: $0)
    }
    if let validation {
      lock.lock()
      expectedBodyLength = validation.expectedBodyLength
      lock.unlock()
    }
    if requestedEnd != nil {
      respond(total: validation?.total)
    } else {
      respond(total: Self.totalLength(of: response, at: start))
    }
    if let refusal = validation?.refusal ?? Self.refusal(of: response, at: start) {
      finish(refusal)
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    meter.received(data.count)
    guard !isCancelled, outcome == nil else {
      lock.unlock()
      return
    }
    if let expectedBodyLength,
       Int64(data.count) > expectedBodyLength - receivedBody {
      lock.unlock()
      finish(.failure(.sourceUnavailable(detail: "HTTP range body exceeds Content-Range"), transient: false))
      dataTask.cancel()
      return
    }
    receivedBody += Int64(data.count)
    buffer.append(data)
    meter.buffered(data.count)
    if !isPaused, Self.shouldPause(buffered: buffer.count) {
      isPaused = true
      if let task { pacing.hold(task) }
    }
    heldSinceData = isPaused
    let waiting = waiters
    waiters.removeAll()
    lock.unlock()
    for continuation in waiting { continuation.resume() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    respond(total: nil)
    lock.lock()
    let incomplete = expectedBodyLength.map { receivedBody < $0 } ?? false
    let bounded = requestedEnd != nil
    let expiredWhileHeld = heldSinceData && (error as? URLError)?.code == .timedOut
    // Only an error that ended the transfer: a refusal already has, and
    // cancelling it afterwards is not the network failing.
    if outcome == nil, let error = error as NSError? { transportError = (error.domain, error.code) }
    lock.unlock()
    switch error {
    case nil:
      if incomplete {
        finish(.failure(.sourceUnavailable(detail: "HTTP range body ended early"), transient: true))
      } else {
        finish(bounded ? .rangeComplete : .end)
      }
    case _ where expiredWhileHeld:
      finish(.expiredWhileHeld)
    case let error as URLError:
      finish(.failure(
        UmbelError.schemeRefusal(error) ?? .sourceUnavailable(detail: UmbelError.detail(for: error)),
        transient: Self.isTransient(error)))
    case let error?:
      // From below the URL layer — CFNetwork's, the sockets' — and not made
      // a URLError of. Only the transfer itself fails so, the source's own
      // refusals being recorded first: a connection that ended, retried as a
      // lost one is, within the same budget.
      finish(.failure(.sourceUnavailable(detail: UmbelError.detail(for: error)), transient: true))
    }
  }
}
