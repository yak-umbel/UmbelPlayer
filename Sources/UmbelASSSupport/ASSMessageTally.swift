import Foundation

/// What libass's messages add up to.
///
/// libass reports through a C callback with a printf-style format. Which
/// message it is shows in the format string, so the tally compares that and
/// never formats anything: most messages are chatter, and a frame with many
/// unresolved glyphs sends hundreds of them.
///
/// Used from the one isolation domain that uses its library, like the
/// library itself.
final class ASSMessageTally: @unchecked Sendable {
  private(set) var unresolvedGlyphs = 0

  /// The formats libass ends a glyph lookup with when nothing could draw it:
  /// no font that has it could be found at all, or the one found does not.
  private static let unresolvedFormats = [
    "fontselect: failed to find any fallback with glyph",
    "Glyph 0x%X not found in font for",
  ]

  static func record(format: UnsafePointer<CChar>, in tally: UnsafeMutableRawPointer) {
    let counter = Unmanaged<ASSMessageTally>.fromOpaque(tally).takeUnretainedValue()
    for prefix in unresolvedFormats where strncmp(format, prefix, prefix.utf8.count) == 0 {
      counter.unresolvedGlyphs += 1
      return
    }
  }
}
