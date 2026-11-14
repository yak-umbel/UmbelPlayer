import Foundation

/// A media playlist: the segments of one rendition, in order.
///
/// Parsing is forgiving where sites commonly slip — a byte order mark,
/// Windows line ends, a missing comma, tags it does not know — and strict
/// about what this player does not play from a playlist of its own yet, so
/// the caller can say so.
internal struct HLSMediaPlaylist: Equatable, Sendable {
  struct Segment: Equatable, Sendable {
    let url: URL
    let duration: Double
    /// Where it starts on the playlist's timeline: the durations before it.
    let start: Double
    /// Its run: the segments between two discontinuity tags, or two
    /// initialisation segments, share one.
    let run: Int
    let byteRange: Range<Int64>?
    /// Its media sequence number.
    var sequence = 0
    /// How it is encrypted; nil when it is not.
    var key: Key?
    /// The initialisation segment it follows, for fragmented MP4; nil for
    /// transport stream segments, which carry everything themselves.
    var map: Map?
  }

  /// A fragmented MP4 initialisation segment: the track headers the
  /// segments after it leave out.
  struct Map: Equatable, Sendable {
    let url: URL
    let byteRange: Range<Int64>?
  }

  /// AES-128 over the whole segment.
  struct Key: Equatable, Sendable {
    let url: URL
    /// Nil when the playlist names none: the segment's sequence number is
    /// its IV then.
    let iv: Data?
  }

  enum ParseError: Error, Equatable {
    case notAPlaylist
    case masterPlaylist
    case unsupported(String)
    case noSegments
  }

  let targetDuration: Double
  let mediaSequence: Int
  let segments: [Segment]
  let isEnded: Bool

  var duration: Double { segments.last.map { $0.start + $0.duration } ?? 0 }

  /// The segment playing at `seconds`: the last to start at or before it.
  func segmentIndex(at seconds: Double) -> Int {
    var low = 0
    var high = segments.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if segments[middle].start <= seconds { low = middle } else { high = middle - 1 }
    }
    return max(0, low)
  }

  static func looksLikePlaylist(_ head: Data) -> Bool {
    let text = String(decoding: head.prefix(64), as: UTF8.self)
    return text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }.hasPrefix("#EXTM3U")
  }

  static func parse(_ text: String, base: URL) throws -> HLSMediaPlaylist {
    let lines = HLSAttributes.lines(of: text)
    guard lines.first == "#EXTM3U" else { throw ParseError.notAPlaylist }

    var targetDuration = 0.0
    var mediaSequence = 0
    var isEnded = false
    var segments: [Segment] = []
    var pendingDuration: Double?
    var pendingRange: (length: Int64, offset: Int64?)?
    var run = 0
    var runHasSegments = false
    var clock = 0.0
    var rangeEnd: Int64 = 0
    var key: Key?
    var map: Map?

    for line in lines.dropFirst() {
      if line.hasPrefix("#") {
        let (tag, value) = HLSAttributes.split(line)
        switch tag {
        case "#EXTINF":
          pendingDuration = Double(value.split(separator: ",", maxSplits: 1).first ?? "") ?? 0
        case "#EXT-X-TARGETDURATION":
          targetDuration = Double(value) ?? 0
        case "#EXT-X-MEDIA-SEQUENCE":
          mediaSequence = Int(value) ?? 0
        case "#EXT-X-DISCONTINUITY":
          if runHasSegments {
            run += 1
            runHasSegments = false
          }
        case "#EXT-X-BYTERANGE":
          let parts = value.split(separator: "@")
          pendingRange = (Int64(parts.first ?? "") ?? 0, parts.count > 1 ? Int64(parts[1]) : nil)
        case "#EXT-X-ENDLIST":
          isEnded = true
        case "#EXT-X-STREAM-INF", "#EXT-X-I-FRAME-STREAM-INF":
          throw ParseError.masterPlaylist
        case "#EXT-X-KEY":
          key = try parseKey(HLSAttributes.parse(value), base: base)
        case "#EXT-X-MAP":
          // The key in force would apply to the headers too, with an IV of
          // their own: rare enough to leave to the fallback.
          if key != nil { throw ParseError.unsupported("EXT-X-MAP with EXT-X-KEY") }
          let next = try parseMap(HLSAttributes.parse(value), base: base)
          // Another encoding: its segments are read with its own headers.
          if next != map, runHasSegments {
            run += 1
            runHasSegments = false
          }
          map = next
        default:
          break  // Tags this player does not need, and comments.
        }
        continue
      }
      guard let url = HLSAttributes.resolve(line, against: base) else { continue }
      let duration = pendingDuration ?? targetDuration
      var byteRange: Range<Int64>?
      if let range = pendingRange {
        // Decrypting part of a file would need the cipher block before it.
        if key != nil { throw ParseError.unsupported("EXT-X-BYTERANGE with EXT-X-KEY") }
        let offset = range.offset ?? rangeEnd
        byteRange = offset..<(offset + range.length)
        rangeEnd = offset + range.length
      }
      segments.append(Segment(
        url: url, duration: duration, start: clock, run: run, byteRange: byteRange,
        sequence: mediaSequence + segments.count, key: key, map: map))
      clock += duration
      runHasSegments = true
      pendingDuration = nil
      pendingRange = nil
    }
    guard !segments.isEmpty else { throw ParseError.noSegments }
    return HLSMediaPlaylist(
      targetDuration: targetDuration, mediaSequence: mediaSequence, segments: segments,
      isEnded: isEnded)
  }

  /// AES-128, or none. Anything else — sample encryption, another cipher —
  /// is not played here.
  private static func parseKey(_ attributes: [String: String], base: URL) throws -> Key? {
    let method = attributes["METHOD"] ?? ""
    switch method {
    case "NONE":
      return nil
    case "AES-128":
      guard let uri = attributes["URI"], let url = HLSAttributes.resolve(uri, against: base) else {
        throw ParseError.unsupported("EXT-X-KEY without URI")
      }
      return Key(url: url, iv: attributes["IV"].flatMap(ivBytes))
    default:
      throw ParseError.unsupported("EXT-X-KEY METHOD=\(method)")
    }
  }

  private static func parseMap(_ attributes: [String: String], base: URL) throws -> Map {
    guard let uri = attributes["URI"], let url = HLSAttributes.resolve(uri, against: base) else {
      throw ParseError.unsupported("EXT-X-MAP without URI")
    }
    var byteRange: Range<Int64>?
    if let range = attributes["BYTERANGE"] {
      let parts = range.split(separator: "@")
      let length = Int64(parts.first ?? "") ?? 0
      let offset = parts.count > 1 ? Int64(parts[1]) ?? 0 : 0
      byteRange = offset..<(offset + length)
    }
    return Map(url: url, byteRange: byteRange)
  }

  /// `0x` and up to 32 hex digits, right-aligned in sixteen bytes.
  private static func ivBytes(_ text: String) -> Data? {
    var hex = text.lowercased()
    if hex.hasPrefix("0x") { hex.removeFirst(2) }
    guard !hex.isEmpty, hex.count <= 32, hex.allSatisfy(\.isHexDigit) else { return nil }
    hex = String(repeating: "0", count: 32 - hex.count) + hex
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
      index = next
    }
    return Data(bytes)
  }
}

/// Where a playlist's segments come from, by position: a fixed list, or a
/// live one that grows as it is fetched again.
internal protocol HLSSegmentSource: Sendable {
  /// The segment at `index`; nil when there is none and will be none. A
  /// live list waits for one yet to come.
  func segment(at index: Int) async throws -> HLSMediaPlaylist.Segment?
  /// Ends any waiting: what waits returns or throws at once.
  func cancel() async
}

extension HLSMediaPlaylist: HLSSegmentSource {
  func segment(at index: Int) -> Segment? {
    segments.indices.contains(index) ? segments[index] : nil
  }

  func cancel() {}
}
