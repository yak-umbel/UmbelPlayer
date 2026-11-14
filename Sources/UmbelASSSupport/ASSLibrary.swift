import Foundation
import LibASS

/// libass's library handle: shared settings and the fonts added in memory.
///
/// Like every libass object it is not thread-safe. The `Sendable` conformance
/// only lets it be handed to the one isolation domain that uses it — the same
/// arrangement as the FFmpeg decoder wrappers.
public final class ASSLibrary: @unchecked Sendable {
  let pointer: OpaquePointer

  /// The version of the libass loaded, such as "0.17.5".
  public static var version: String { version(fromNumber: ass_library_version()) }

  /// libass's number read as its digits: 0x01705000 is 0.17.5 — one digit
  /// for the major version, two for the minor, two for the patch, and the
  /// release status after them dropped.
  static func version(fromNumber number: Int32) -> String {
    let digits = Array(String(format: "%08x", number))
    func value(_ range: ClosedRange<Int>) -> Int { Int(String(digits[range])) ?? 0 }
    return "\(value(0...0)).\(value(1...2)).\(value(3...4))"
  }

  public init() {
    // ass_library_init only fails on allocation failure.
    pointer = ass_library_init()!
    // libass prints to stderr by default, and it is chatty: missing glyphs and
    // font fallbacks are reported on every render. None of it is actionable
    // from inside a player, so it is silenced.
    ass_set_message_cb(pointer, { _, _, _, _ in }, nil)
    // A script can carry its fonts in a [Fonts] section, in the file or in a
    // container track's header. libass decodes them either way but keeps
    // them only when asked to; without this, lines set in them fall back to
    // another font.
    ass_set_extract_fonts(pointer, 1)
  }

  deinit {
    ass_library_done(pointer)
  }

  /// Makes a font available by the name the script uses — a Matroska
  /// attachment, say. Renderers created afterwards, or refreshed with
  /// `ASSRenderer.reloadFonts()`, can use it.
  public func addFont(named name: String, data: Data) {
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      ass_add_font(
        pointer, name, base.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
    }
  }
}
