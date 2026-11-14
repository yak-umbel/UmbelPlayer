import Foundation

/// A server that insists on a Referer, as the sites hosts play from do, and
/// answers ranges. `/moved` redirects to another host, for checking where a
/// source ends up.
final class HeaderStubProtocol: URLProtocol {
  static let payload = Data((0..<256).map { UInt8($0) })
  static let referer = "https://site.invalid/"
  static let headers = ["Referer": referer]

  private static let lock = NSLock()
  nonisolated(unsafe) private static var log: [String] = []

  nonisolated(unsafe) private static var published: [String: [Data]] = [:]
  nonisolated(unsafe) private static var fetches: [String: Int] = [:]

  /// Serves `text` at `path` from now on, for a playlist a test writes.
  static func publish(_ text: String, at path: String) {
    publish([text], at: path)
  }

  /// Serves each of `texts` at `path` in turn, a fetch from the start
  /// moving on to the next — a live playlist growing — and the last from
  /// then on. Reading on from further in gets the one being read.
  static func publish(_ texts: [String], at path: String) {
    lock.lock()
    published[path] = texts.map { Data($0.utf8) }
    fetches[path] = 0
    lock.unlock()
  }

  private static func publishedBody(at path: String, fromStart: Bool) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard let versions = published[path], !versions.isEmpty else { return nil }
    let fetched = fetches[path] ?? 0
    if fromStart { fetches[path] = fetched + 1 }
    return versions[min(max(fromStart ? fetched : fetched - 1, 0), versions.count - 1)]
  }

  /// "GET <path>" and "HEAD <path>" for every request answered so far.
  static var requests: [String] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeaderStubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.lock.lock()
    Self.log.append("\(request.httpMethod ?? "GET") \(url.path)")
    Self.lock.unlock()
    if url.path == "/moved" || url.path == "/moved-master" {
      var next = request
      next.url = URL(string: url.path == "/moved"
        ? "https://cdn.invalid/media.bin" : "https://cdn.invalid/hls/master.m3u8")!
      let moved = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": next.url!.absoluteString])!
      client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: moved)
      return
    }
    guard request.value(forHTTPHeaderField: "Referer") == Self.referer else {
      finish(url, 403, [:], Data())
      return
    }
    let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
    let fromStart = request.httpMethod != "HEAD" && range.hasPrefix("bytes=0-")
    if let body = Self.publishedBody(at: url.path, fromStart: fromStart) {
      serve(body, url)
      return
    }
    // /encoded: a server that compresses what it sends unless asked not to,
    // its ranges counting the compressed bytes — sixty-four of them here.
    // The system's networking asks for compression by itself and undoes it,
    // so ranges read from it land in another representation.
    if url.path == "/encoded" {
      let identity = request.value(forHTTPHeaderField: "Accept-Encoding") == "identity"
      serve(identity ? Self.payload : Data(repeating: 0xEE, count: 64), url)
      return
    }
    // /hls/…: the playlist fixtures, as a site would serve them.
    if url.path.hasPrefix("/hls/") {
      let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(String(url.path.dropFirst()))
      guard let body = try? Data(contentsOf: file) else {
        finish(url, 404, [:], Data())
        return
      }
      serve(body, url)
      return
    }
    serve(Self.payload, url)
  }

  override func stopLoading() {}

  /// Answers HEAD with the length and GET with the range asked for.
  private func serve(_ payload: Data, _ url: URL) {
    if request.httpMethod == "HEAD" {
      finish(url, 200, ["Content-Length": "\(payload.count)"], Data())
      return
    }
    let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
    let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? "0") ?? 0
    guard start < payload.count else {
      finish(url, 416, ["Content-Range": "bytes */\(payload.count)"], Data())
      return
    }
    let body = payload.subdata(in: start..<payload.count)
    finish(url, 206, [
      "Content-Range": "bytes \(start)-\(payload.count - 1)/\(payload.count)",
      "Content-Length": "\(body.count)",
    ], body)
  }

  private func finish(_ url: URL, _ status: Int, _ headers: [String: String], _ body: Data) {
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
    client?.urlProtocolDidFinishLoading(self)
  }
}
