import Foundation

/// HEVC's NAL units as containers carry them: in samples behind a length of
/// one to four bytes, or after start codes in a transport stream; and the
/// parameter sets in an hvcC record's arrays.
internal enum HEVCParameterSets {
  typealias Sets = (vps: Data, sps: Data, pps: Data)

  /// The units of a sample, each behind a `lengthSize`-byte big-endian
  /// length — or, with no length size, after start codes (Annex B). A unit
  /// cut short is dropped, not read past.
  static func units(in data: Data, lengthSize: Int?) -> [Data] {
    let bytes = [UInt8](data)
    guard let lengthSize else { return annexBUnits(bytes) }
    var units: [Data] = []
    var at = 0
    while at + lengthSize <= bytes.count {
      let length = bytes[at..<(at + lengthSize)].reduce(0) { $0 << 8 | Int($1) }
      at += lengthSize
      guard length > 0, at + length <= bytes.count else { break }
      units.append(Data(bytes[at..<(at + length)]))
      at += length
    }
    return units
  }

  /// Split on 00 00 01, a zero before it counting as part of the start code.
  private static func annexBUnits(_ bytes: [UInt8]) -> [Data] {
    var starts: [(code: Int, unit: Int)] = []
    var at = 0
    while at + 2 < bytes.count {
      if bytes[at] == 0, bytes[at + 1] == 0, bytes[at + 2] == 1 {
        let code = at > 0 && bytes[at - 1] == 0 ? at - 1 : at
        starts.append((code, at + 3))
        at += 3
      } else {
        at += 1
      }
    }
    return starts.indices.compactMap { index in
      let end = index + 1 < starts.count ? starts[index + 1].code : bytes.count
      let begin = starts[index].unit
      return begin < end ? Data(bytes[begin..<end]) : nil
    }
  }

  /// The units again, each behind a 4-byte big-endian length.
  static func lengthPrefixed(_ units: [Data]) -> Data {
    var out = Data()
    for unit in units {
      let length = UInt32(unit.count).bigEndian
      withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
      out.append(unit)
    }
    return out
  }

  /// The unit's type: bits 1–6 of its first byte.
  static func type(of unit: Data) -> UInt8? {
    unit.first.map { ($0 >> 1) & 0x3F }
  }

  /// VPS, SPS and PPS (types 32, 33 and 34), the first of each; nil unless
  /// all three are there.
  static func parameterSets(in units: [Data]) -> Sets? {
    var found: [UInt8: Data] = [:]
    for unit in units {
      guard let type = type(of: unit), (32...34).contains(type), found[type] == nil else { continue }
      found[type] = unit
    }
    guard let vps = found[32], let sps = found[33], let pps = found[34] else { return nil }
    return (vps, sps, pps)
  }

  // ── hvcC ────────────────────────────────────────────
  // 22 bytes of profile and format, then the number of arrays; each array a
  // byte whose low six bits are the unit type, a 2-byte count, and that many
  // units behind 2-byte lengths.

  static func hvcCHasArrays(_ hvcC: Data) -> Bool {
    hvcC.count >= 23 && hvcC[hvcC.startIndex + 22] > 0
  }

  /// The length size the record's samples use: its byte 21's low two bits, plus one.
  static func lengthSize(ofHvcC hvcC: Data) -> Int {
    guard hvcC.count >= 22 else { return 4 }
    return Int(hvcC[hvcC.startIndex + 21] & 0x03) + 1
  }

  /// The record's VPS, SPS and PPS; nil unless all three are there.
  static func arrays(inHvcC hvcC: Data) -> Sets? {
    let bytes = [UInt8](hvcC)
    guard bytes.count >= 23 else { return nil }
    var units: [Data] = []
    var at = 23
    for _ in 0..<Int(bytes[22]) {
      guard at + 3 <= bytes.count else { return nil }
      let count = Int(bytes[at + 1]) << 8 | Int(bytes[at + 2])
      at += 3
      for _ in 0..<count {
        guard at + 2 <= bytes.count else { return nil }
        let length = Int(bytes[at]) << 8 | Int(bytes[at + 1])
        at += 2
        guard at + length <= bytes.count else { return nil }
        units.append(Data(bytes[at..<(at + length)]))
        at += length
      }
    }
    return parameterSets(in: units)
  }
}
