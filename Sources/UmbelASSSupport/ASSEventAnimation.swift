import Foundation

/// Which lines change by themselves as time passes.
///
/// From the script format: an override block, between braces, can hold a
/// transform (`\t`), a move (`\move`), a fade (`\fad`, `\fade`) or a
/// karaoke sweep (`\k`, `\K`, `\kf`, `\ko`), and the Effect field can name a
/// scrolling or banner effect. Anything else — position, colour, blur, clip,
/// rotation, font — holds a line still.
///
/// Wrongly calling a still line animated only costs redrawing it; wrongly
/// calling a moving line still would freeze it. So this errs toward animated:
/// any tag that begins like one of these counts, whatever follows.
enum ASSEventAnimation {
  static func changesWithTime(
    effect: UnsafePointer<CChar>?, text: UnsafePointer<CChar>?
  ) -> Bool {
    if let effect, effect.pointee != 0 { return true }
    guard var cursor = text else { return false }
    var inBlock = false
    while cursor.pointee != 0 {
      switch UInt8(bitPattern: cursor.pointee) {
      case UInt8(ascii: "{"):
        inBlock = true
      case UInt8(ascii: "}"):
        inBlock = false
      case UInt8(ascii: "\\") where inBlock:
        let tag = cursor + 1
        switch UInt8(bitPattern: tag.pointee) {
        case UInt8(ascii: "t"), UInt8(ascii: "k"), UInt8(ascii: "K"):
          return true
        case UInt8(ascii: "m") where begins(tag, with: "move"):
          return true
        case UInt8(ascii: "f") where begins(tag, with: "fad"):
          return true
        default:
          break
        }
      default:
        break
      }
      cursor += 1
    }
    return false
  }

  /// Whether the C string at `cursor` starts with `name`. Stops at the
  /// first difference, so it never reads past the terminator.
  private static func begins(_ cursor: UnsafePointer<CChar>, with name: StaticString) -> Bool {
    for offset in 0..<name.utf8CodeUnitCount
    where UInt8(bitPattern: cursor[offset]) != name.utf8Start[offset] {
      return false
    }
    return true
  }
}
