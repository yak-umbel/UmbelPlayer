import Foundation

/// One GET, read in order as it arrives: the connection beneath
/// `UmbelLiveHTTPSource`.
///
/// The bytes go into a `LiveByteQueue`; above its high watermark the
/// URLSession task is suspended, below the low one it goes on. A class with
/// no lock of its own: the session's delegate calls arrive on its own queue
/// and hand over synchronously, and everything they touch is the queue's or
/// is only touched there.
final class HTTPLiveBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let queue: LiveByteQueue

  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var expectedLength: Int64?
  private var receivedLength: Int64 = 0
  private var failureIsRetryable = false

  /// Whether a failure that ended the stream is one a new request could get
  /// past: a server's 5xx, a connection that did not hold. Only read once
  /// the queue has said how the stream ended.
  var isTransientFailure: Bool {
    lock.lock(); defer { lock.unlock() }
    return failureIsRetryable
  }

  init(url: URL, session: URLSession, headers: [String: String], pacing: HTTPRangeStream.Pacing) {
    // The queue's hold and release need the task, made after the queue.
    let holder = TaskHolder()
    queue = LiveByteQueue(
      hold: { if let task = holder.task { pacing.hold(task) } },
      release: { if let task = holder.task { pacing.release(task) } })
    super.init()
    var request = URLRequest(url: url)
    // The host's headers, then the content as it is: no compression.
    HTTPRangeStream.apply(headers, to: &request)
    let task = session.dataTask(with: request)
    task.delegate = self
    lock.lock()
    self.task = task
    lock.unlock()
    holder.task = task
    task.resume()
  }

  /// Stops the transfer and fails every read, waiting or to come, as
  /// interrupted. What was held back is let go first, so the cancel is clean.
  func cancel() {
    queue.close()
    lock.lock()
    let task = self.task
    lock.unlock()
    task?.cancel()
  }

  private func end(with failure: UmbelError, transient: Bool) {
    lock.lock()
    failureIsRetryable = transient
    lock.unlock()
    queue.finish(.failure(failure))
  }

  // ── The session's delegate calls ────────────────────

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      end(with: .sourceUnavailable(detail: "not an HTTP response"), transient: false)
      completionHandler(.cancel)
      return
    }
    // Only a whole response: no range was asked for, so no other status is
    // what was asked.
    guard http.statusCode == 200 else {
      end(with: .sourceUnavailable(detail: "HTTP \(http.statusCode)"),
          transient: HTTPRangeStream.isTransient(status: http.statusCode))
      completionHandler(.cancel)
      return
    }
    lock.lock()
    expectedLength = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    receivedLength += Int64(data.count)
    lock.unlock()
    queue.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let incomplete = expectedLength.map { receivedLength < $0 } ?? false
    lock.unlock()
    switch error {
    case nil:
      // A response that said how long it was and stopped short was cut, not
      // finished.
      if incomplete {
        end(with: .sourceUnavailable(detail: "HTTP body ended early"), transient: true)
      } else {
        queue.finish(.end)
      }
    case let error as URLError:
      end(with: UmbelError.schemeRefusal(error) ?? .sourceUnavailable(detail: UmbelError.detail(for: error)),
          transient: HTTPRangeStream.isTransient(error))
    case let error?:
      // From below the URL layer, and not made a URLError of: the connection
      // ended, as a lost one does.
      end(with: .sourceUnavailable(detail: UmbelError.detail(for: error)), transient: true)
    }
  }
}

/// Hands the task to the queue's hold and release, which are made before it.
private final class TaskHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var current: URLSessionDataTask?

  var task: URLSessionDataTask? {
    get { lock.lock(); defer { lock.unlock() }; return current }
    set { lock.lock(); current = newValue; lock.unlock() }
  }
}
