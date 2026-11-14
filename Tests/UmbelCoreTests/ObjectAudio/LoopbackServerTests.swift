import Foundation
import Network
import XCTest
@testable import UmbelCore

private actor Flag {
  private(set) var isRaised = false
  func raise() { isRaised = true }
}

/// The one listener serving generated segments to the system player: on
/// this machine's loopback only, a port the system picks, each session's
/// resources under a secret path.
final class LoopbackServerTests: XCTestCase {
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
  }()

  private static func get(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Int, Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    let (data, response) = try await session.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return (http.statusCode, data, http)
  }

  private static func hello(_ name: String) -> LoopbackServer.Resource? {
    name == "a.txt" ? .init(data: Data("hello".utf8), contentType: "text/plain") : nil
  }

  func testARegisteredResourceIsServedOnLoopback() async throws {
    let server = LoopbackServer()
    let base = try await server.register { Self.hello($0) }
    XCTAssertEqual(base.host, "127.0.0.1")
    let (status, body, response) = try await Self.get(base.appendingPathComponent("a.txt"))
    XCTAssertEqual(status, 200)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/plain")
    await server.unregister(base)
  }

  func testAnythingElseIsNotFound() async throws {
    let server = LoopbackServer()
    let base = try await server.register { Self.hello($0) }
    let (unknown, _, _) = try await Self.get(base.appendingPathComponent("b.txt"))
    XCTAssertEqual(unknown, 404)
    var components = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
    components.path = "/wrong-token/a.txt"
    let (stranger, _, _) = try await Self.get(try XCTUnwrap(components.url))
    XCTAssertEqual(stranger, 404, "another path gets nothing, however it guesses the name")
    let (post, _, _) = try await Self.get(base.appendingPathComponent("a.txt"), method: "POST")
    XCTAssertEqual(post, 405)
    await server.unregister(base)
  }

  func testARangeIsServedAlone() async throws {
    let server = LoopbackServer()
    let base = try await server.register { Self.hello($0) }
    let (status, body, response) = try await Self.get(base.appendingPathComponent("a.txt"), range: "bytes=1-3")
    XCTAssertEqual(status, 206)
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "ell")
    XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 1-3/5")
    await server.unregister(base)
  }

  /// A segment not yet read is answered when it is; others go meanwhile.
  func testAnAnswerCanWaitWithoutHoldingOthers() async throws {
    let server = LoopbackServer()
    let base = try await server.register { name in
      if name == "slow" { try await Task.sleep(nanoseconds: 300_000_000) }
      return .init(data: Data(name.utf8), contentType: "text/plain")
    }
    async let slow = Self.get(base.appendingPathComponent("slow"))
    let started = Date()
    let (_, quick, _) = try await Self.get(base.appendingPathComponent("quick"))
    XCTAssertEqual(String(decoding: quick, as: UTF8.self), "quick")
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.25, "not behind the slow one")
    let (_, late, _) = try await slow
    XCTAssertEqual(String(decoding: late, as: UTF8.self), "slow")
    await server.unregister(base)
  }

  /// The player closes the connection of a request it gives up on, after a
  /// seek; an answer still waiting for reading stops there.
  func testAnAnswerStopsWhenItsAskerGoesAway() async throws {
    let server = LoopbackServer()
    let cancelled = Flag()
    let asked = Flag()
    let base = try await server.register { _ in
      await asked.raise()
      do {
        try await Task.sleep(nanoseconds: 10_000_000_000)
      } catch {
        await cancelled.raise()
        throw error
      }
      return nil
    }
    let port = try XCTUnwrap(base.port.flatMap { NWEndpoint.Port(rawValue: UInt16($0)) })
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    connection.start(queue: .global())
    let head = "GET \(base.appendingPathComponent("slow").path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    try await Task.sleep(nanoseconds: 200_000_000)
    let arrived = await asked.isRaised
    XCTAssertTrue(arrived)
    let early = await cancelled.isRaised
    XCTAssertFalse(early, "still waiting while asked")
    connection.cancel()
    for _ in 0..<40 where await !cancelled.isRaised {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let late = await cancelled.isRaised
    XCTAssertTrue(late)
    await server.unregister(base)
  }

  func testTheListenerClosesWithTheLastRegistration() async throws {
    let server = LoopbackServer()
    let first = try await server.register { Self.hello($0) }
    let second = try await server.register { Self.hello($0) }
    XCTAssertEqual(first.port, second.port, "one listener for all")
    XCTAssertNotEqual(first.path, second.path)
    await server.unregister(first)
    let (still, _, _) = try await Self.get(second.appendingPathComponent("a.txt"))
    XCTAssertEqual(still, 200)
    await server.unregister(second)
    do {
      _ = try await Self.get(second.appendingPathComponent("a.txt"))
      XCTFail("nothing listens once the last goes")
    } catch {}
  }
}
