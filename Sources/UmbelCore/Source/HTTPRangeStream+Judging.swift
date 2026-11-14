import Foundation

/// Judging what came back: a response, or the error a transfer ended with.
extension HTTPRangeStream {
  /// The whole length a response gives: after the slash of a range's
  /// `Content-Range` ("bytes 0-99/256", or "bytes */256" past the end), or
  /// the length of all of it sent from byte 0. "*" says it is not known.
  static func totalLength(of response: URLResponse, at offset: Int64) -> Int64? {
    guard let http = response as? HTTPURLResponse else { return nil }
    switch http.statusCode {
    case 206, 416:
      guard let range = http.value(forHTTPHeaderField: "Content-Range"),
            let slash = range.lastIndex(of: "/") else { return nil }
      return Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    case 200 where offset == 0:
      return http.expectedContentLength >= 0 ? http.expectedContentLength : nil
    default:
      return nil
    }
  }

  /// Why a response cannot be read on, or nil if it can. A 416 — the range
  /// starts past the end — is the end of the content.
  static func refusal(of response: URLResponse, at offset: Int64) -> Piece? {
    guard let http = response as? HTTPURLResponse else {
      return .failure(.sourceUnavailable(detail: "not an HTTP response"), transient: false)
    }
    switch http.statusCode {
    case 206:
      return nil
    case 200:
      // The server ignored the range and sends the whole content from byte
      // 0. Read from 0, that is just what was asked for — playlists served
      // by scripts and proxies commonly come so. From anywhere else, the
      // layers above would get misplaced bytes, and a server that ignores
      // ranges cannot seek: say so at once rather than turn it into garbage
      // no one above can trace.
      guard offset != 0 else { return nil }
      return .failure(
        .sourceUnavailable(detail: "the server ignored the range request; no random access"),
        transient: false)
    case 416:
      return .end
    default:
      return .failure(
        .sourceUnavailable(detail: "HTTP \(http.statusCode)"),
        transient: isTransient(status: http.statusCode))
    }
  }

  /// Transient: the server said so itself with a 5xx, 408 or 429. Anything
  /// else — a 404, a server that ignores ranges — would answer the same way
  /// again.
  static func isTransient(status: Int) -> Bool {
    status == 408 || status == 429 || (500...599).contains(status)
  }

  static func isTransient(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet,
         .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
         .resourceUnavailable, .internationalRoamingOff, .callIsActive,
         .dataNotAllowed:
      return true
    default:
      return false
    }
  }
}
