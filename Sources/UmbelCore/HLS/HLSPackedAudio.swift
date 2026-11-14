import Foundation

/// Segments that are sound alone — "packed audio": raw AAC, MP3, AC-3 or
/// E-AC-3 frames, most often behind an ID3 tag carrying their timestamp.
/// Not transport streams: read as one, a run of them is probed until the
/// probe gives up, and on a live playlist that waits on the playlist for
/// ever. Told by their first bytes, they go to FFmpeg's reading at once.
internal enum HLSPackedAudio {
  static func isPackedAudio(_ head: Data) -> Bool {
    let bytes = [UInt8](head.prefix(3))
    guard bytes.count >= 2 else { return false }
    if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return true }  // ID3
    if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return true }  // MPEG audio and ADTS frames
    return bytes[0] == 0x0B && bytes[1] == 0x77  // AC-3 and E-AC-3 frames
  }
}
