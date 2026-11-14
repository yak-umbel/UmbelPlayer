import CoreMedia
import Foundation

/// Turns one ASS dialogue line into a cue.
///
/// This is every text format's last step, not just ASS's: FFmpeg's SRT, WebVTT
/// and mov_text decoders all emit the same `ReadOrder,Layer,Style,Name,MarginL,
/// MarginR,MarginV,Effect,Text` line.
///
/// A subset of override tags is honoured — the ones a cue can express. Every
/// other tag is recognised and dropped while its text stays: losing a style is
/// acceptable, losing words is not.
internal enum ASSDialogue {
  static func cue(
    from line: String, styles: ASSStyleSheet, start: CMTime, end: CMTime?
  ) -> UmbelSubtitleCue {
    let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
    // Fewer than nine fields: not a dialogue line at all, so all of it is text.
    let isDialogue = fields.count == 9
    let style = styles.resolvedStyle(named: isDialogue ? trimmed(fields[2]) : "Default")
    let text = isDialogue ? String(fields[8]) : line

    func margin(_ index: Int, _ fallback: Double) -> Double {
      guard isDialogue, let value = Double(trimmed(fields[index])), value != 0 else {
        return fallback
      }
      return value
    }

    var parser = Parser(style: style, styles: styles)
    parser.parse(text)

    return UmbelSubtitleCue(
      start: start,
      end: end,
      runs: parser.runs,
      alignment: parser.alignment ?? style.alignment,
      relativeFontSize: style.fontSize / styles.playResY,
      margins: UmbelSubtitleMargins(
        left: margin(4, style.marginLeft) / styles.playResX,
        right: margin(5, style.marginRight) / styles.playResX,
        vertical: margin(6, style.marginVertical) / styles.playResY),
      outlineColor: style.outlineColor,
      relativeOutlineWidth: style.outlineWidth / styles.playResY,
      fontName: style.fontName)
  }

  private static func trimmed(_ text: Substring) -> String {
    text.trimmingCharacters(in: .whitespaces)
  }
}

/// Walks the text once, splitting it into runs wherever the style changes.
private struct Parser {
  private struct RunStyle: Equatable {
    var isBold: Bool
    var isItalic: Bool
    var isUnderlined: Bool
    var isStruckThrough: Bool
    var color: UmbelColor

    init(_ style: ASSStyle) {
      isBold = style.isBold
      isItalic = style.isItalic
      isUnderlined = style.isUnderlined
      isStruckThrough = style.isStruckThrough
      color = style.primaryColor
    }
  }

  private let lineStyle: ASSStyle
  private let styles: ASSStyleSheet
  private var current: RunStyle
  private var pending = ""
  private var pendingStyle: RunStyle
  private var isDrawing = false

  private(set) var runs: [UmbelSubtitleCue.Run] = []
  /// The first alignment tag wins, as in the reference renderer.
  private(set) var alignment: UmbelSubtitleAlignment?

  init(style: ASSStyle, styles: ASSStyleSheet) {
    lineStyle = style
    self.styles = styles
    current = RunStyle(style)
    pendingStyle = current
  }

  mutating func parse(_ text: String) {
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "{", let close = text[index...].firstIndex(of: "}") {
        applyBlock(text[text.index(after: index)..<close])
        index = text.index(after: close)
        continue
      }
      if character == "\\" {
        let next = text.index(after: index)
        if next < text.endIndex, let escaped = Self.escape(text[next]) {
          append(escaped)
          index = text.index(after: next)
          continue
        }
      }
      append(character)
      index = text.index(after: index)
    }
    flush()
  }

  /// `\N` is a hard break. `\n` breaks only under a wrap style we do not
  /// implement, so it reads as a space, as it does by default in ASS.
  private static func escape(_ character: Character) -> Character? {
    switch character {
    case "N": return "\n"
    case "n": return " "
    case "h": return "\u{00A0}"
    default: return nil
    }
  }

  private mutating func append(_ character: Character) {
    guard !isDrawing else { return }
    if current != pendingStyle {
      flush()
      pendingStyle = current
    }
    pending.append(character)
  }

  private mutating func flush() {
    guard !pending.isEmpty else { return }
    runs.append(
      UmbelSubtitleCue.Run(
        text: pending,
        isBold: pendingStyle.isBold,
        isItalic: pendingStyle.isItalic,
        isUnderlined: pendingStyle.isUnderlined,
        isStruckThrough: pendingStyle.isStruckThrough,
        color: pendingStyle.color))
    pending = ""
  }

  /// Splits a `{...}` block into tags. A backslash inside parentheses belongs
  /// to the enclosing tag — `\t(0,500,\fscx120)` is one tag, not two.
  private mutating func applyBlock(_ block: Substring) {
    var tags: [Substring] = []
    var depth = 0
    var tagStart: Substring.Index?
    for index in block.indices {
      switch block[index] {
      case "(":
        depth += 1
      case ")":
        depth = max(0, depth - 1)
      case "\\" where depth == 0:
        if let start = tagStart { tags.append(block[start..<index]) }
        tagStart = block.index(after: index)
      default:
        break
      }
    }
    if let start = tagStart { tags.append(block[start...]) }
    for tag in tags { apply(tag.trimmingCharacters(in: .whitespaces)) }
  }

  private mutating func apply(_ tag: String) {
    if let value = Self.argument(of: tag, after: "alpha") {
      if let alpha = Self.alpha(value) { current.color.alpha = alpha }
    } else if let value = Self.argument(of: tag, after: "an") {
      if alignment == nil, let raw = Int(value) {
        alignment = UmbelSubtitleAlignment(rawValue: raw)
      }
    } else if let value = Self.argument(of: tag, after: "a"), Self.isDigits(value) {
      if alignment == nil, let raw = Int(value) {
        alignment = ASSStyleSheet.legacyAlignment(raw)
      }
    } else if let value = Self.argument(of: tag, after: "1c") ?? Self.colourArgument(tag) {
      let parsed = value.isEmpty ? lineStyle.primaryColor : ASSStyleSheet.color(value)
      if let parsed {
        current.color = UmbelColor(
          red: parsed.red, green: parsed.green, blue: parsed.blue, alpha: current.color.alpha)
      }
    } else if let value = Self.argument(of: tag, after: "1a") {
      if let alpha = Self.alpha(value) { current.color.alpha = alpha }
    } else if let first = tag.first, "ibusp".contains(first) {
      let value = String(tag.dropFirst())
      guard Self.isDigits(value) else { return }   // \shad, \blur, \pos: not ours
      applyToggle(first, value: Int(value))
    } else if tag.first == "r" {
      let name = String(tag.dropFirst())
      current = RunStyle(name.isEmpty ? lineStyle : styles.resolvedStyle(named: name))
    }
  }

  /// An empty value restores the line's style, as ASS specifies.
  private mutating func applyToggle(_ tag: Character, value: Int?) {
    let base = RunStyle(lineStyle)
    switch tag {
    case "i": current.isItalic = value.map { $0 != 0 } ?? base.isItalic
    case "u": current.isUnderlined = value.map { $0 != 0 } ?? base.isUnderlined
    case "s": current.isStruckThrough = value.map { $0 != 0 } ?? base.isStruckThrough
    // Bold also takes a weight; treat semibold and up as bold.
    case "b": current.isBold = value.map { $0 == 1 || $0 >= 600 } ?? base.isBold
    case "p": isDrawing = (value ?? 0) > 0
    default: break
    }
  }

  private static func argument(of tag: String, after name: String) -> String? {
    tag.hasPrefix(name) ? String(tag.dropFirst(name.count)) : nil
  }

  /// `\c` is the only tag spelled with a bare "c"; `\clip` must not match.
  private static func colourArgument(_ tag: String) -> String? {
    guard tag.hasPrefix("c") else { return nil }
    let value = String(tag.dropFirst())
    return value.isEmpty || value.hasPrefix("&") ? value : nil
  }

  private static func alpha(_ value: String) -> Double? {
    let digits = value.uppercased()
      .replacingOccurrences(of: "&H", with: "")
      .replacingOccurrences(of: "&", with: "")
    guard let raw = UInt8(digits, radix: 16) else { return nil }
    return Double(255 - raw) / 255
  }

  private static func isDigits(_ text: String) -> Bool {
    text.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
