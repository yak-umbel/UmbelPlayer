import Foundation

/// FFmpeg's error codes, sorted.
///
/// FFmpeg's error constants are C macros that Swift does not import, so they
/// are worked out again here from their definitions:
///   MKTAG(a,b,c,d)    = a | b<<8 | c<<16 | d<<24
///   FFERRTAG(a,b,c,d) = -MKTAG(a,b,c,d)
/// Unit tests pin the values; end-to-end tests check again that codes from
/// real calls fall into these classes.
public enum FFmpegErrorCode: Equatable, Sendable {
  case endOfFile
  case invalidData
  case interrupted
  case io(Int32)

  private static func tag(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int32 {
    let value = UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24
    return -Int32(bitPattern: value)
  }

  /// AVERROR_EOF
  public static let endOfFileRaw: Int32 = tag(0x45, 0x4F, 0x46, 0x20)      // 'E','O','F',' '
  /// AVERROR_INVALIDDATA
  public static let invalidDataRaw: Int32 = tag(0x49, 0x4E, 0x44, 0x41)    // 'I','N','D','A'
  /// AVERROR_EXIT: what FFmpeg returns when the interrupt callback fires.
  public static let exitRaw: Int32 = tag(0x45, 0x58, 0x49, 0x54)           // 'E','X','I','T'
  /// Backpressure: receive pending output before retrying the same input.
  /// This is a codec state transition, not a damaged packet.
  public static let tryAgainRaw: Int32 = -EAGAIN

  /// Nil for anything not negative, which is not an error.
  public static func classifyIfError(_ raw: Int32) -> FFmpegErrorCode? {
    raw < 0 ? classify(raw) : nil
  }

  public static func classify(_ raw: Int32) -> FFmpegErrorCode {
    switch raw {
    case endOfFileRaw: return .endOfFile
    case invalidDataRaw: return .invalidData
    case exitRaw: return .interrupted
    default: return .io(raw)
    }
  }
}
