import Foundation

/// Checks raw SUP framing and bitmap dimensions before handing bytes to the decoder.
internal enum ExternalSUPInspector {
  static let maxPictureBytes = 32 * 1_024 * 1_024
  static let maxRetainedBitmapBytes = 64 * 1_024 * 1_024
  static let maxCanvasSide = 8_192
  static let maxBitmapCues = 20_000

  private struct PartialObject {
    var remaining: Int
    let bitmapBytes: Int
  }

  static func isSUP(_ data: Data) -> Bool {
    data.count >= 2 && data[0] == 0x50 && data[1] == 0x47
  }

  static func validate(_ data: Data) throws {
    try Task.checkCancellation()
    guard isSUP(data) else { throw malformed("missing PG signature") }
    var offset = 0
    var composition: [UInt16]?
    var objects: [UInt16: Int] = [:]
    var partial: [UInt16: PartialObject] = [:]
    var totalBitmapBytes = 0
    var definedBitmapBytes = 0
    var bitmapCueCount = 0
    var displaySetCount = 0

    while offset < data.count {
      try Task.checkCancellation()
      guard data.count - offset >= 13, data[offset] == 0x50,
            data[offset + 1] == 0x47 else {
        throw malformed("truncated segment header")
      }
      let length = word(data, offset + 11)
      let start = offset + 13
      guard length <= data.count - start else {
        throw malformed("truncated segment payload")
      }
      let end = start + length
      switch data[offset + 10] {
      case 0x16:
        guard composition == nil, length >= 11,
              (1...maxCanvasSide).contains(word(data, start)),
              (1...maxCanvasSide).contains(word(data, start + 2)) else {
          throw malformed("invalid presentation segment")
        }
        var cursor = start + 11
        var references: [UInt16] = []
        for _ in 0..<Int(data[start + 10]) {
          try Task.checkCancellation()
          guard end - cursor >= 8 else { throw malformed("truncated picture reference") }
          references.append(UInt16(word(data, cursor)))
          let cropped = data[cursor + 3] & 0x80 != 0
          cursor += cropped ? 16 : 8
          guard cursor <= end else { throw malformed("truncated picture crop") }
        }
        guard cursor == end else { throw malformed("invalid presentation length") }
        composition = references

      case 0x15:
        guard length >= 4 else { throw malformed("short picture segment") }
        let id = UInt16(word(data, start))
        let flags = data[start + 3]
        if flags & 0x80 != 0 {
          guard length >= 11 else { throw malformed("short picture definition") }
          let declared = (Int(data[start + 4]) << 16)
            | (Int(data[start + 5]) << 8) | Int(data[start + 6])
          let width = word(data, start + 7)
          let height = word(data, start + 9)
          guard declared >= 4, width > 0, height > 0,
                width <= maxPictureBytes / 4 / height else {
            throw malformed("picture exceeds decoded bitmap limit")
          }
          let remaining = declared - 4 - (length - 11)
          guard remaining >= 0 else { throw malformed("picture data exceeds declared length") }
          let bitmapBytes = width * height * 4
          guard bitmapBytes <= maxRetainedBitmapBytes - definedBitmapBytes else {
            throw malformed("decoded picture definitions exceed memory limit")
          }
          definedBitmapBytes += bitmapBytes
          if flags & 0x40 != 0 {
            guard remaining == 0 else { throw malformed("incomplete picture data") }
            objects[id] = bitmapBytes
            partial.removeValue(forKey: id)
          } else {
            partial[id] = PartialObject(remaining: remaining, bitmapBytes: bitmapBytes)
          }
        } else {
          guard var object = partial[id] else { throw malformed("orphan picture fragment") }
          object.remaining -= length - 4
          guard object.remaining >= 0 else { throw malformed("picture data exceeds declared length") }
          if flags & 0x40 != 0 {
            guard object.remaining == 0 else { throw malformed("incomplete picture data") }
            objects[id] = object.bitmapBytes
            partial.removeValue(forKey: id)
          } else {
            partial[id] = object
          }
        }

      case 0x14:
        // Palette ID and version, followed by whole five-byte entries.
        guard length >= 2, (length - 2) % 5 == 0 else {
          throw malformed("invalid palette segment length")
        }

      case 0x17:
        // Count byte, then ID, position and dimensions for every window.
        guard length >= 1, length == 1 + Int(data[start]) * 9 else {
          throw malformed("invalid window segment length")
        }

      case 0x80:
        guard length == 0, let references = composition, partial.isEmpty else {
          throw malformed("incomplete display set")
        }
        guard references.count <= maxBitmapCues - bitmapCueCount else {
          throw malformed("too many bitmap cues")
        }
        bitmapCueCount += references.count
        for id in references {
          try Task.checkCancellation()
          guard let bitmapBytes = objects[id],
                bitmapBytes <= maxRetainedBitmapBytes - totalBitmapBytes else {
            throw malformed("decoded bitmap retention limit exceeded")
          }
          totalBitmapBytes += bitmapBytes
        }
        composition = nil
        displaySetCount += 1

      default:
        throw malformed("unknown SUP segment")
      }
      offset = end
    }
    guard displaySetCount > 0, composition == nil, partial.isEmpty else {
      throw malformed("incomplete SUP stream")
    }
  }

  private static func word(_ data: Data, _ offset: Int) -> Int {
    (Int(data[offset]) << 8) | Int(data[offset + 1])
  }

  private static func malformed(_ detail: String) -> UmbelError {
    .unsupportedContainer("malformed SUP: \(detail)")
  }
}
