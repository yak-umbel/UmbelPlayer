import Foundation

/// MP4 boxes read and written only as far as fragmented sound needs:
/// sizes and types, and the few fields fragments must agree with.
internal enum MP4Box {
  /// The boxes directly inside `range` (the whole data by default): each
  /// type with the range of its contents. Stops at the first box that does
  /// not fit.
  static func children(of data: Data, in range: Range<Int>? = nil) -> [(type: String, contents: Range<Int>)] {
    let bounds = range ?? data.startIndex..<data.endIndex
    var boxes: [(String, Range<Int>)] = []
    var offset = bounds.lowerBound
    while offset + 8 <= bounds.upperBound {
      let size = Int(readUInt32(data, at: offset))
      guard size >= 8, offset + size <= bounds.upperBound else { break }
      let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
      boxes.append((type, offset + 8..<offset + size))
      offset += size
    }
    return boxes
  }

  /// The contents of the box at `path`, each step the first of its type.
  static func find(_ path: [String], in data: Data) -> Range<Int>? {
    var range: Range<Int>? = nil
    for type in path {
      guard let found = children(of: data, in: range).first(where: { $0.type == type }) else { return nil }
      range = found.contents
    }
    return range
  }

  static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }

  /// A box of `type` around `payload`.
  static func make(_ type: String, _ payload: Data) -> Data {
    var box = Data()
    box.appendUInt32(UInt32(8 + payload.count))
    box.append(contentsOf: Array(type.utf8))
    box.append(payload)
    return box
  }

  /// A full box: version and flags first.
  static func makeFull(_ type: String, version: UInt8, flags: UInt32, _ payload: Data) -> Data {
    var head = Data([version])
    head.append(contentsOf: [UInt8(flags >> 16 & 0xFF), UInt8(flags >> 8 & 0xFF), UInt8(flags & 0xFF)])
    return make(type, head + payload)
  }
}

extension Data {
  mutating func appendUInt32(_ value: UInt32) {
    append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
  }

  mutating func appendUInt64(_ value: UInt64) {
    appendUInt32(UInt32(value >> 32))
    appendUInt32(UInt32(value & 0xFFFF_FFFF))
  }
}
