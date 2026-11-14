import Foundation
import UmbelCore

/// Reads through a connection that goes silent, served by `relay.js`; see
/// README.md. `run.sh` starts the relay and runs every mode.
///
///     umbel-silent-connection-check system <port> [timeout]
///     umbel-silent-connection-check source <port> renew|keep [timeout]
@main
enum SilentConnectionCheck {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2, let port = Int(arguments[1]) else { usage() }
    let url = URL(string: "https://127.0.0.1:\(port)/content")!
    switch arguments[0] {
    case "system":
      let timeout = arguments.count > 2 ? Double(arguments[2]) ?? 2 : 2
      await SystemCheck(url: url, timeout: timeout).run()
    case "source" where arguments.count >= 3 && ["renew", "keep"].contains(arguments[2]):
      let timeout = arguments.count > 3 ? Double(arguments[3]) ?? 2 : 2
      let renew = arguments[2] == "renew"
      let readOn = await SourceCheck(url: url, timeout: timeout, renew: renew).run()
      // Only reading on with a maker is asked of the source; without one,
      // the outcome says what the system does with the kept session.
      exit(renew && !readOn ? 1 : 0)
    default:
      usage()
    }
  }

  static func usage() -> Never {
    FileHandle.standardError.write(Data("""
      usage: umbel-silent-connection-check system <port> [timeout]
             umbel-silent-connection-check source <port> renew|keep [timeout]

      """.utf8))
    exit(2)
  }
}

/// Trusts the relay's self-signed certificate. That the session has a
/// delegate matters: without a maker, UmbelHTTPSource keeps such a session.
final class TrustingDelegate: NSObject, URLSessionDelegate, Sendable {
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
  ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
    guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
    return (.useCredential, URLCredential(trust: trust))
  }
}

func makeSession(timeout: TimeInterval) -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.urlCache = nil
  configuration.connectionProxyDictionary = [:]
  configuration.timeoutIntervalForRequest = timeout
  return URLSession(configuration: configuration, delegate: TrustingDelegate(), delegateQueue: nil)
}

/// The byte the relay serves at `offset`.
func expectedByte(at offset: Int64) -> UInt8 { UInt8((offset &* 37 &+ 11) % 251) }

// ── URLSession alone ─────────────────────────────────

/// URLSession as a source uses it: read until the request times out, retry
/// three times on the same session with growing waits, then once on a fresh
/// session. Says, per request, whether it rode a connection already open.
struct SystemCheck {
  let url: URL
  let timeout: TimeInterval

  func run() async {
    let session = makeSession(timeout: timeout)
    let first = await request(on: session, from: 0, stopAfter: nil)
    print(first.line("first"))
    var retries: [RequestRecord] = []
    var wait: UInt64 = 250_000_000
    for retry in 1...3 {
      try? await Task.sleep(nanoseconds: wait)
      wait *= 2
      let record = await request(on: session, from: first.received, stopAfter: 1 << 20)
      print(record.line("retry \(retry)"))
      retries.append(record)
    }
    let fresh = await request(on: makeSession(timeout: timeout), from: first.received, stopAfter: 1 << 20)
    print(fresh.line("fresh session"))
    let stuck = retries.allSatisfy { $0.reused && !$0.responded }
    print(stuck && fresh.responded
      ? "reproduced: the retries rode the silent connection; a fresh session read on"
      : "not reproduced: the retries did not all ride the silent connection")
  }

  private func request(on session: URLSession, from offset: Int64, stopAfter: Int64?) async -> RequestRecord {
    var request = URLRequest(url: url)
    request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    let probe = TaskProbe(stopAfter: stopAfter)
    let task = session.dataTask(with: request)
    task.delegate = probe
    let began = Date()
    task.resume()
    await probe.finished()
    return probe.record(elapsed: Date().timeIntervalSince(began))
  }
}

struct RequestRecord {
  let received: Int64
  let status: Int?
  let errorCode: Int?
  let reused: Bool
  let responded: Bool
  let localPort: Int?
  let elapsed: TimeInterval

  func line(_ label: String) -> String {
    let error = errorCode.map { "URL error \($0)" } ?? "none"
    return "\(label): \(received) bytes, status \(status.map(String.init) ?? "none"), error \(error), "
      + "connection \(reused ? "reused" : "new") (local port \(localPort.map(String.init) ?? "?")), "
      + "\(responded ? "answered" : "no answer"), \(String(format: "%.2f", elapsed)) s"
  }
}

/// One request's delegate: counts what arrives, stops after enough, and
/// keeps the metrics.
final class TaskProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let stopAfter: Int64?
  private var received: Int64 = 0
  private var status: Int?
  private var errorCode: Int?
  private var metrics: URLSessionTaskMetrics?
  private var isComplete = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(stopAfter: Int64?) { self.stopAfter = stopAfter }

  /// Returns once the request has completed and its metrics have come, or
  /// half a second after completing without them.
  func finished() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let done = lock.withLock {
        if isComplete { return true }
        waiter = continuation
        return false
      }
      if done { continuation.resume() }
    }
    for _ in 0..<10 where lock.withLock({ metrics == nil }) {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  func record(elapsed: TimeInterval) -> RequestRecord {
    lock.withLock {
      let transaction = metrics?.transactionMetrics.last
      return RequestRecord(
        received: received, status: status, errorCode: errorCode,
        reused: transaction?.isReusedConnection ?? false,
        responded: transaction?.responseStartDate != nil,
        localPort: transaction?.localPort, elapsed: elapsed)
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse
  ) async -> URLSession.ResponseDisposition {
    lock.withLock { status = (response as? HTTPURLResponse)?.statusCode }
    return .allow
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let enough = lock.withLock {
      received += Int64(data.count)
      return stopAfter.map { received >= $0 } ?? false
    }
    if enough { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
    lock.withLock { self.metrics = metrics }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let waiting = lock.withLock {
      errorCode = (error as? URLError)?.code.rawValue
      isComplete = true
      defer { waiter = nil }
      return waiter
    }
    waiting?.resume()
  }
}

// ── UmbelHTTPSource ──────────────────────────────────

/// UmbelHTTPSource reading 8 MiB, past where the relay goes silent, with a
/// session maker or without one.
struct SourceCheck {
  let url: URL
  let timeout: TimeInterval
  let renew: Bool

  /// Whether every byte was read, as served, after a session renewal.
  func run() async -> Bool {
    let maker: (@Sendable () -> URLSession)?
    if renew {
      maker = { [timeout] in makeSession(timeout: timeout) }
    } else {
      maker = nil
    }
    let source = UmbelHTTPSource(
      url: url, session: makeSession(timeout: timeout),
      retryPolicy: .init(maxRetries: 3, initialDelay: 0.25, jitter: 0), makeSession: maker)
    let target: Int64 = 8 << 20
    var offset: Int64 = 0
    var mismatch: Int64?
    var failure: Error?
    let began = Date()
    do {
      while offset < target {
        let piece = try await source.read(offset: offset, maxLength: 256 << 10)
        if piece.isEmpty { break }
        for (index, byte) in piece.enumerated() where mismatch == nil && byte != expectedByte(at: offset + Int64(index)) {
          mismatch = offset + Int64(index)
        }
        offset += Int64(piece.count)
      }
    } catch {
      failure = error
    }
    let statistics = await source.transferStatistics
    let last = await source.lastFailure
    await source.invalidate()

    let outcome = failure.map { "failed (\($0))" } ?? "read on"
    let bytes = mismatch.map { "wrong byte at \($0)" } ?? "bytes as served"
    print("\(renew ? "with a maker" : "without one"): \(outcome), \(offset) of \(target) bytes, \(bytes), "
      + "\(statistics.requestCount) requests, \(statistics.sessionRenewals) session renewals, "
      + String(format: "%.1f s", Date().timeIntervalSince(began)))
    if let last {
      print("  last failure: URL error \(last.urlErrorCode.map { String($0.rawValue) } ?? "none"), "
        + "HTTP \(last.httpStatus.map(String.init) ?? "none"), read at \(last.offset), attempt \(last.attempts)")
    }
    return failure == nil && offset >= target && mismatch == nil && statistics.sessionRenewals > 0
  }
}
