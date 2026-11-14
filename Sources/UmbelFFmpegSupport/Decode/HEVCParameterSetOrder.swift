import Foundation

/// Keeps parameter sets that follow a picture for the next sample. HEVC
/// hardware decoding can reject the current picture when its sample ends
/// with the next picture's VPS/SPS/PPS. No sets are discarded: they precede
/// the next sample's own headers, so a later configuration still wins.
public struct HEVCParameterSetOrder: Sendable {
  /// Nil for Annex B; otherwise the hvcC length field's size in bytes.
  let lengthSize: Int?
  private var pending = Data()

  public init(lengthSize: Int?) { self.lengthSize = lengthSize }

  public mutating func reset() { pending.removeAll() }

  public mutating func prepare(_ data: Data) -> Data {
    // Empty input is the decoder's drain signal, never a headers packet.
    guard !data.isEmpty, let units = data.withUnsafeBytes({ units(in: $0) }) else { return data }
    var sawPicture = false
    var moved: [Range<Int>] = []
    for unit in units {
      if unit.type < 32 { sawPicture = true }
      if sawPicture, (32...34).contains(unit.type) { moved.append(unit.range) }
    }
    guard !pending.isEmpty || !moved.isEmpty else { return data }
    var result = pending
    pending = Data()
    var copied = 0
    for range in moved {
      result.append(contentsOf: data[(data.startIndex + copied)..<(data.startIndex + range.lowerBound)])
      pending.append(contentsOf: data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)])
      copied = range.upperBound
    }
    result.append(contentsOf: data[(data.startIndex + copied)..<data.endIndex])
    return result
  }

  private struct Unit {
    let type: UInt8
    /// Includes the length field or the original start code.
    let range: Range<Int>
  }

  /// Validate the whole sample before changing it. Damaged framing stays
  /// with the decoder's existing error handling, without consuming pending
  /// sets or silently truncating the packet.
  private func units(in bytes: UnsafeRawBufferPointer) -> [Unit]? {
    guard let lengthSize else { return annexBUnits(in: bytes) }
    guard (1...4).contains(lengthSize) else { return nil }
    var found: [Unit] = []
    var at = 0
    while at < bytes.count {
      let start = at
      guard bytes.count - at >= lengthSize else { return nil }
      var length = 0
      for _ in 0..<lengthSize {
        length = (length << 8) | Int(bytes[at])
        at += 1
      }
      guard length >= 2, length <= bytes.count - at else { return nil }
      found.append(Unit(type: (bytes[at] >> 1) & 63, range: start..<(at + length)))
      at += length
    }
    return found
  }

  private func annexBUnits(in bytes: UnsafeRawBufferPointer) -> [Unit]? {
    var starts: [(code: Int, payload: Int)] = []
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
    guard starts.first?.code == 0 else { return nil }
    var found: [Unit] = []
    for index in starts.indices {
      let start = starts[index]
      let end = index + 1 < starts.count ? starts[index + 1].code : bytes.count
      guard end - start.payload >= 2 else { return nil }
      found.append(Unit(type: (bytes[start.payload] >> 1) & 63, range: start.code..<end))
    }
    return found
  }
}
