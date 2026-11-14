import Foundation

enum HTTPRangeResponse {
  struct Validation {
    let total: Int64?
    let expectedBodyLength: Int64?
    let refusal: HTTPRangeStream.Piece?
  }

  static func validate(_ response: URLResponse, start: Int64, requestedEnd: Int64) -> Validation {
    let malformed = Validation(total: nil, expectedBodyLength: nil,
      refusal: .failure(.sourceUnavailable(detail: "invalid Content-Range"), transient: false))
    guard let http = response as? HTTPURLResponse else { return malformed }
    if http.statusCode == 416 {
      guard let header = http.value(forHTTPHeaderField: "Content-Range"),
            header.hasPrefix("bytes */"),
            let total = decimal(header.dropFirst("bytes */".count)),
            start >= total else { return malformed }
      return .init(total: total, expectedBodyLength: nil, refusal: .end)
    }
    guard http.statusCode == 206 else {
      return .init(total: nil, expectedBodyLength: nil,
                   refusal: HTTPRangeStream.refusal(of: response, at: start) ??
                     .failure(.sourceUnavailable(detail: "server ignored finite range"), transient: false))
    }
    guard let header = http.value(forHTTPHeaderField: "Content-Range"),
          header.hasPrefix("bytes ") else { return malformed }
    let pieces = header.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 2, let total = parseTotal(pieces[1]) else { return malformed }
    let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, let lower = decimal(bounds[0]), let upper = decimal(bounds[1]),
          lower == start, upper >= lower, upper <= requestedEnd,
          total.map({ upper < $0 }) ?? true else { return malformed }
    let span = upper - lower
    guard span < Int64.max else { return malformed }
    let length = span + 1
    if let headerLength = http.value(forHTTPHeaderField: "Content-Length"),
       decimal(headerLength[...]) != length { return malformed }
    return .init(total: total, expectedBodyLength: length, refusal: nil)
  }

  /// Outer optional distinguishes invalid text from a valid unknown total.
  private static func parseTotal(_ text: Substring) -> Int64?? {
    if text == "*" { return .some(nil) }
    guard let number = decimal(text) else { return nil }
    return .some(number)
  }

  private static func decimal(_ text: Substring) -> Int64? {
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int64(text)
  }
}
