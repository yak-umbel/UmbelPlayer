import Foundation

/// A request's head, parsed as far as the loopback server needs.
internal struct LoopbackRequest: Sendable {
  let method: String
  let path: String
  let keepAlive: Bool
  /// "bytes=a-b", "bytes=a-" or "bytes=-n", when asked for.
  let range: String?

  init?(head: Data) {
    let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
    let first = lines.first?.split(separator: " ") ?? []
    guard first.count == 3 else { return nil }
    method = String(first[0])
    path = String(first[1].split(separator: "?").first ?? "")
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    // HTTP/1.1 keeps the connection unless told otherwise.
    keepAlive = first[2] == "HTTP/1.1" && headers["connection"]?.lowercased() != "close"
    range = headers["range"]
  }
}

/// A response, head and body.
internal struct LoopbackResponse: Sendable {
  let status: Int
  let headers: [(String, String)]
  let body: Data

  static func plain(_ status: Int) -> LoopbackResponse {
    LoopbackResponse(status: status, headers: [], body: Data())
  }

  /// A resource whole, or the part a range asks for.
  init(resource: LoopbackServer.Resource, range: String?, bodyless: Bool) {
    let total = resource.data.count
    var headers = [("Content-Type", resource.contentType), ("Accept-Ranges", "bytes")]
    guard let range else {
      self.init(status: 200, headers: headers, body: bodyless ? Data() : resource.data, length: total)
      return
    }
    guard let bounds = Self.bounds(of: range, total: total) else {
      headers.append(("Content-Range", "bytes */\(total)"))
      self.init(status: 416, headers: headers, body: Data())
      return
    }
    headers.append(("Content-Range", "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(total)"))
    let part = resource.data.subdata(in: bounds)
    self.init(status: 206, headers: headers, body: bodyless ? Data() : part, length: part.count)
  }

  private init(status: Int, headers: [(String, String)], body: Data, length: Int? = nil) {
    self.status = status
    self.headers = headers + [("Content-Length", String(length ?? body.count))]
    self.body = body
  }

  func bytes(keepAlive: Bool) -> Data {
    let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found",
                  405: "Method Not Allowed", 416: "Range Not Satisfiable", 500: "Internal Server Error"][status] ?? "OK"
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    for (name, value) in headers + [("Connection", keepAlive ? "keep-alive" : "close")] {
      head += "\(name): \(value)\r\n"
    }
    return Data((head + "\r\n").utf8) + body
  }

  private static func bounds(of range: String, total: Int) -> Range<Int>? {
    guard range.hasPrefix("bytes="), total > 0 else { return nil }
    let spec = range.dropFirst(6).split(separator: ",").first ?? ""
    let ends = spec.split(separator: "-", omittingEmptySubsequences: false)
    guard ends.count == 2 else { return nil }
    if ends[0].isEmpty {
      guard let suffix = Int(ends[1]), suffix > 0 else { return nil }
      return max(0, total - suffix)..<total
    }
    guard let first = Int(ends[0]), first < total else { return nil }
    let last = ends[1].isEmpty ? total - 1 : min(Int(ends[1]) ?? total - 1, total - 1)
    guard last >= first else { return nil }
    return first..<last + 1
  }
}
