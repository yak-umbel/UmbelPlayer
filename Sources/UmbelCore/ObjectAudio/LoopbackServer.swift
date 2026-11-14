import Foundation
import Network

/// Serves generated segments to the system player over this machine's
/// loopback: one listener for the process, on a port the system picks, each
/// registration's resources under a random secret path.
///
/// The system player takes a segment only over HTTP — a resource loader may
/// answer its playlist, but a segment only with a redirect to HTTP — so they
/// are served here. Only loopback connects; anything but the secret paths,
/// and any method but GET and HEAD, is refused. Other programs on the same
/// machine can reach the port, which is what the secret is for.
internal final class LoopbackServer: @unchecked Sendable {
  struct Resource: Sendable {
    let data: Data
    let contentType: String
  }

  /// Answers a name under a registration's path: nil for none (404); a throw
  /// for one that could not be made (500).
  typealias Handler = @Sendable (String) async throws -> Resource?

  static let shared = LoopbackServer()

  // Everything below is touched on `queue` only.
  private let queue = DispatchQueue(label: "umbel.loopback")
  private var listener: NWListener?
  private var port: UInt16?
  private var handlers: [String: Handler] = [:]
  private var waiting: [CheckedContinuation<UInt16, Error>] = []
  /// Open connections, closed with the listener: a connection kept alive
  /// would otherwise go on reaching a server that has stopped.
  private var exchanges: [ObjectIdentifier: Exchange] = [:]

  /// A connection, what it has sent and not yet had answered, and the
  /// answer being made. Reading goes on while one is: the player closes a
  /// connection when it gives up on a request — after a seek — and the
  /// answer, perhaps waiting for reading far away, is then cancelled.
  private struct Exchange {
    let connection: NWConnection
    var received = Data()
    var isAnswering = false
    var answering: Task<Void, Never>?
  }

  /// Starts listening if nothing was; returns the base address of a new
  /// registration's resources, ending in `/`.
  func register(_ handler: @escaping Handler) async throws -> URL {
    let token = Self.secret()
    let port: UInt16
    do {
      port = try await withCheckedThrowingContinuation { continuation in
        queue.async {
          self.handlers[token] = handler
          self.whenListening(continuation)
        }
      }
    } catch {
      // Not listening: nothing will ever be asked of it.
      queue.async { self.handlers[token] = nil }
      throw error
    }
    guard let base = URL(string: "http://127.0.0.1:\(port)/\(token)/") else { throw URLError(.badURL) }
    return base
  }

  /// Removes a registration; the last one gone, the listener closes.
  func unregister(_ base: URL) async {
    let token = base.pathComponents.dropFirst().first ?? ""
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        self.handlers[token] = nil
        if self.handlers.isEmpty { self.close() }
        continuation.resume()
      }
    }
  }

  // ── Listening ───────────────────────────────────────

  private func whenListening(_ continuation: CheckedContinuation<UInt16, Error>) {
    if let port { return continuation.resume(returning: port) }
    waiting.append(continuation)
    guard listener == nil else { return }
    do {
      let parameters = NWParameters.tcp
      // On the loopback address, so only this device can connect. Not
      // `acceptLocalOnly` as well: the iOS simulator then refuses every
      // connection, its filter failing to set up.
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
      let made = try NWListener(using: parameters)
      made.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
      made.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener = made
      made.start(queue: queue)
    } catch {
      fail(error)
    }
  }

  private func listenerChanged(_ state: NWListener.State) {
    switch state {
    case .ready:
      guard let ready = listener?.port?.rawValue else { return }
      port = ready
      let resumed = waiting
      waiting = []
      for continuation in resumed { continuation.resume(returning: ready) }
    case .failed(let error):
      fail(error)
    default:
      break
    }
  }

  private func fail(_ error: Error) {
    close()
    let resumed = waiting
    waiting = []
    for continuation in resumed { continuation.resume(throwing: error) }
  }

  private func close() {
    listener?.cancel()
    listener = nil
    port = nil
    for exchange in exchanges.values {
      exchange.answering?.cancel()
      exchange.connection.cancel()
    }
    exchanges = [:]
  }

  // ── Connections ─────────────────────────────────────

  private func accept(_ connection: NWConnection) {
    let key = ObjectIdentifier(connection)
    exchanges[key] = Exchange(connection: connection)
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .cancelled, .failed: self?.exchanges.removeValue(forKey: key)?.answering?.cancel()
      default: break
      }
    }
    connection.start(queue: queue)
    receive(key)
  }

  /// Reads for as long as the connection is open, answering one request at
  /// a time.
  private func receive(_ key: ObjectIdentifier) {
    guard let connection = exchanges[key]?.connection else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self, self.exchanges[key] != nil else { return connection.cancel() }
      if let data { self.exchanges[key]?.received.append(data) }
      guard !isComplete, error == nil else { return connection.cancel() }
      self.answerNext(key)
      self.receive(key)
    }
  }

  /// Answers the next request once its head is whole, unless one is being
  /// answered.
  private func answerNext(_ key: ObjectIdentifier) {
    guard var exchange = exchanges[key], !exchange.isAnswering else { return }
    guard let end = exchange.received.range(of: Data("\r\n\r\n".utf8)) else {
      if exchange.received.count > 16_384 { exchange.connection.cancel() }
      return
    }
    let request = LoopbackRequest(head: exchange.received[exchange.received.startIndex..<end.lowerBound])
    exchange.received = Data(exchange.received[end.upperBound...])
    exchange.isAnswering = true
    exchanges[key] = exchange
    answer(request, key)
  }

  private func answer(_ request: LoopbackRequest?, _ key: ObjectIdentifier) {
    guard let request else { return send(.plain(400), key, keepAlive: false) }
    guard request.method == "GET" || request.method == "HEAD" else {
      return send(.plain(405), key, keepAlive: request.keepAlive)
    }
    let parts = request.path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2, let handler = handlers[String(parts[0])] else {
      return send(.plain(404), key, keepAlive: request.keepAlive)
    }
    let name = String(parts[1])
    exchanges[key]?.answering = Task { [weak self] in
      let response: LoopbackResponse
      do {
        if let resource = try await handler(name) {
          response = LoopbackResponse(resource: resource, range: request.range, bodyless: request.method == "HEAD")
        } else {
          response = .plain(404)
        }
      } catch {
        response = .plain(500)
      }
      self?.queue.async { self?.send(response, key, keepAlive: request.keepAlive) }
    }
  }

  private func send(_ response: LoopbackResponse, _ key: ObjectIdentifier, keepAlive: Bool) {
    guard let connection = exchanges[key]?.connection else { return }
    connection.send(content: response.bytes(keepAlive: keepAlive), completion: .contentProcessed { [weak self] error in
      guard let self, error == nil, keepAlive else { return connection.cancel() }
      self.queue.async {
        self.exchanges[key]?.isAnswering = false
        self.exchanges[key]?.answering = nil
        self.answerNext(key)
      }
    })
  }

  /// 128 random bits, in hex.
  private static func secret() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<2).map { _ in String(format: "%016llx", generator.next()) }.joined()
  }
}
