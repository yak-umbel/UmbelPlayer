import Foundation
import Network

/// A local HTTP/1.1 peer for URLSession integration tests. All connection work
/// runs on a queue separate from XCTest and URLSession's delegate queue.
final class HTTPTransportTestServer: @unchecked Sendable {
  enum Behavior {
    case complete
    case pause(after: Int)
    case interruptFirst(after: Int)
  }

  struct Request: Equatable, Sendable {
    let path: String
    let range: String
    let connectionID: Int
  }

  struct Snapshot {
    let requests: [Request]
    let acceptedConnections: Int
    /// Bytes whose NWConnection send completion reported success. This is not
    /// a count of bytes received by URLSession or by the source's caller.
    let completedBodyWrites: Int64
    let closedRanges: [String]
  }

  private let queue = DispatchQueue(label: "UmbelHTTPTransportTestServer")
  private let lock = NSLock()
  private let listener: NWListener
  private let bodyLength: Int
  private let behavior: Behavior
  private var requests: [Request] = []
  private var acceptedConnections = 0
  private var completedBodyWrites: Int64 = 0
  private var closedRanges: [String] = []
  private var connections: [NWConnection] = []
  private var paused: [@Sendable () -> Void] = []
  private var didInterrupt = false

  init(bodyLength: Int, behavior: Behavior = .complete) throws {
    precondition(bodyLength > 0)
    self.bodyLength = bodyLength
    self.behavior = behavior
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready, .failed:
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
      listener.cancel()
      throw URLError(.cannotConnectToHost)
    }
  }

  var url: URL {
    URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/content")!
  }

  func url(path: String) -> URL {
    URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")!
  }

  static func byte(at offset: Int) -> UInt8 {
    UInt8((offset &* 37 &+ 11) % 251)
  }

  func snapshot() -> Snapshot {
    lock.lock(); defer { lock.unlock() }
    return Snapshot(requests: requests, acceptedConnections: acceptedConnections,
                    completedBodyWrites: completedBodyWrites,
                    closedRanges: closedRanges)
  }

  func releasePausedResponses() {
    queue.async {
      let continuations = self.paused
      self.paused.removeAll()
      continuations.forEach { $0() }
    }
  }

  func stop() {
    queue.sync {
      listener.cancel()
      connections.forEach { $0.cancel() }
      connections.removeAll()
      paused.removeAll()
    }
  }

  private func accept(_ connection: NWConnection) {
    connections.append(connection)
    lock.lock()
    acceptedConnections += 1
    let connectionID = acceptedConnections
    lock.unlock()
    connection.start(queue: queue)
    receiveRequest(on: connection, id: connectionID, accumulated: Data())
  }

  private func receiveRequest(on connection: NWConnection, id: Int, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var bytes = accumulated
      if let data { bytes.append(data) }
      guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
        if !complete, error == nil, bytes.count < 8192 {
          self.receiveRequest(on: connection, id: id, accumulated: bytes)
        } else {
          connection.cancel()
        }
        return
      }
      let head = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
      let lines = head.components(separatedBy: "\r\n")
      let parts = (lines.first ?? "").split(separator: " ")
      guard parts.count >= 2 else { connection.cancel(); return }
      let range = lines.dropFirst().first {
        $0.lowercased().hasPrefix("range:")
      }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
      let request = Request(path: String(parts[1]), range: range, connectionID: id)
      self.lock.lock()
      self.requests.append(request)
      self.lock.unlock()
      self.respond(to: request, on: connection)
      switch self.behavior {
      case .complete:
        break // The next GET is read after this response finishes writing.
      case .pause, .interruptFirst:
        self.watchClose(on: connection, range: range)
      }
    }
  }

  private func watchClose(on connection: NWConnection, range: String) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
      [weak self] _, _, complete, error in
      guard let self else { return }
      if complete || error != nil {
        self.lock.lock()
        self.closedRanges.append(range)
        self.lock.unlock()
      } else {
        self.watchClose(on: connection, range: range)
      }
    }
  }

  private func respond(to request: Request, on connection: NWConnection) {
    let specification = request.range.hasPrefix("bytes=")
      ? String(request.range.dropFirst(6)) : "0-"
    let endpoints = specification.split(separator: "-", omittingEmptySubsequences: false)
    guard endpoints.count == 2, let start = Int(endpoints[0]), start >= 0,
          (endpoints[1].isEmpty || Int(endpoints[1]) != nil) else {
      connection.cancel()
      return
    }
    if start >= bodyLength {
      let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(bodyLength)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
      })
      return
    }
    let end = min(endpoints[1].isEmpty ? bodyLength - 1 : Int(endpoints[1])!, bodyLength - 1)
    guard end >= start else { connection.cancel(); return }
    let body = GeneratedBody(start: start, count: end - start + 1)
    let connectionHeader: String
    if case .complete = behavior { connectionHeader = "keep-alive" }
    else { connectionHeader = "close" }
    let header = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(bodyLength)\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: \(connectionHeader)\r\n\r\n"
    connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
      guard let self, error == nil else { return }
      switch self.behavior {
      case .complete:
        self.send(body, from: 0, on: connection) {
          self.receiveRequest(on: connection, id: request.connectionID, accumulated: Data())
        }
      case .pause(let count):
        let split = min(max(0, count), body.count)
        self.send(body.prefix(split), from: 0, on: connection) {
          self.paused.append { self.send(body, from: split, on: connection) }
        }
      case .interruptFirst(let count) where !self.didInterrupt:
        self.didInterrupt = true
        let split = min(max(1, count), body.count - 1)
        self.send(body.prefix(split), from: 0, on: connection) {
          connection.cancel()
        }
      case .interruptFirst:
        self.send(body, from: 0, on: connection)
      }
    })
  }

  private func send(
    _ body: GeneratedBody, from index: Int, on connection: NWConnection,
    completion: (@Sendable () -> Void)? = nil
  ) {
    guard index < body.count else {
      if let completion {
        completion()
      } else {
        connection.send(content: nil, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
      }
      return
    }
    let next = min(index + 1024, body.count)
    let chunk = body.subdata(in: index..<next)
    connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
      guard let self, error == nil else { return }
      self.lock.lock()
      self.completedBodyWrites += Int64(chunk.count)
      self.lock.unlock()
      self.send(body, from: next, on: connection, completion: completion)
    })
  }
}

/// A response's body, worked out as it is sent. Made up front, a body of
/// megabytes held the first byte back for longer than a client's timeout, in
/// a build without optimisation on a slow machine.
private struct GeneratedBody: Sendable {
  let start: Int
  let count: Int

  func prefix(_ length: Int) -> GeneratedBody { GeneratedBody(start: start, count: length) }

  func subdata(in range: Range<Int>) -> Data {
    Data(range.map { HTTPTransportTestServer.byte(at: start + $0) })
  }
}
