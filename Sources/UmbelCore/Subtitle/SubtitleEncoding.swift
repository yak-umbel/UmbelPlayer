import Foundation

/// Turns a subtitle file's bytes into UTF-8, whatever they were written in.
///
/// FFmpeg's text demuxers read UTF-8 only, while subtitles in the wild —
/// especially Chinese ones — are often GBK or Big5. The platform's own
/// detector finds the encoding and adds no dependency.
internal enum SubtitleEncoding {
  /// UTF-8 bytes without a byte order mark, or nil when no encoding fits.
  static func utf8(from data: Data) -> Data? {
    let utf8Mark: [UInt8] = [0xEF, 0xBB, 0xBF]
    if data.starts(with: utf8Mark) { return Data(data.dropFirst(utf8Mark.count)) }
    // A byte order mark settles it. UTF-32's is checked first: its
    // little-endian mark begins with UTF-16's.
    if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
      return String(data: data, encoding: .utf32).map { Data($0.utf8) }
    }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      return String(data: data, encoding: .utf16).map { Data($0.utf8) }
    }
    if String(data: data, encoding: .utf8) != nil { return data }
    return detected(data).map { Data($0.utf8) }
  }

  /// Most likely encodings first. Chinese leads because the problem is most
  /// common there; Windows-1252 last, since any byte sequence decodes as it.
  private static let candidates: [String.Encoding] = [
    encoding(.GB_18030_2000), encoding(.big5), .shiftJIS, encoding(.EUC_KR), .windowsCP1252,
  ]

  private static func detected(_ data: Data) -> String? {
    var converted: NSString?
    var lossy: ObjCBool = false
    let found = NSString.stringEncoding(
      for: data,
      encodingOptions: [
        .suggestedEncodingsKey: candidates.map { NSNumber(value: $0.rawValue) },
        .useOnlySuggestedEncodingsKey: true,
        .allowLossyKey: false,
      ],
      convertedString: &converted,
      usedLossyConversion: &lossy)
    guard found != 0, !lossy.boolValue else { return nil }
    return converted as String?
  }

  private static func encoding(_ encoding: CFStringEncodings) -> String.Encoding {
    String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
  }
}
