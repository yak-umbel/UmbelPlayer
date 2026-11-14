import Foundation

/// One `Style:` line of an ASS header, in the script's own coordinates.
internal struct ASSStyle: Sendable, Equatable {
  var name: String
  var fontName: String
  var fontSize: Double
  var primaryColor: UmbelColor
  var outlineColor: UmbelColor
  var isBold: Bool
  var isItalic: Bool
  var isUnderlined: Bool
  var isStruckThrough: Bool
  var outlineWidth: Double
  var alignment: UmbelSubtitleAlignment
  var marginLeft: Double
  var marginRight: Double
  var marginVertical: Double

  /// The style FFmpeg writes for formats that have none, such as SRT. Used
  /// whenever a header names no usable style, so both paths look alike.
  static let fallback = ASSStyle(
    name: "Default", fontName: "Arial", fontSize: 16,
    primaryColor: .white, outlineColor: .black,
    isBold: false, isItalic: false, isUnderlined: false, isStruckThrough: false,
    outlineWidth: 1, alignment: .bottomCenter,
    marginLeft: 10, marginRight: 10, marginVertical: 10)
}

/// The styles and script resolution from a subtitle header.
///
/// Every text subtitle reaches us with one: ASS tracks carry their own, and
/// FFmpeg writes a default for the formats it converts. Columns are located by
/// the `Format:` line rather than by position — authors reorder them, and the
/// older SSA layout has different ones.
internal struct ASSStyleSheet: Sendable {
  let playResX: Double
  let playResY: Double
  private let styles: [ASSStyle]

  init(header: String) {
    var info: [String: String] = [:]
    var styles: [ASSStyle] = []
    var section = ""
    var format: [String] = []

    for rawLine in header.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") {
        section = line.lowercased()
        format = []
        continue
      }
      guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(";") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

      switch section {
      case "[script info]":
        info[key.lowercased()] = value
      case "[v4+ styles]", "[v4 styles]":
        if key.lowercased() == "format" {
          format = value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
          }
        } else if key.lowercased() == "style", !format.isEmpty {
          let legacy = section == "[v4 styles]"
          styles.append(Self.style(value, format: format, legacyAlignment: legacy))
        }
      default:
        continue
      }
    }

    // The reference renderer's rules for a missing resolution.
    let x = info["playresx"].flatMap(Double.init)
    let y = info["playresy"].flatMap(Double.init)
    switch (x, y) {
    case let (x?, y?):
      playResX = x
      playResY = y
    case let (nil, y?):
      playResX = y * 4 / 3
      playResY = y
    case let (x?, nil):
      playResX = x
      playResY = x == 1280 ? 1024 : x * 3 / 4
    case (nil, nil):
      playResX = 384
      playResY = 288
    }
    self.styles = styles
  }

  func style(named name: String) -> ASSStyle? {
    styles.first { $0.name == name }
      ?? styles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// The named style, else `Default`, else the first one, else FFmpeg's.
  /// A line naming a style that does not exist is common in the wild and
  /// still has to show.
  func resolvedStyle(named name: String) -> ASSStyle {
    style(named: name) ?? style(named: "Default") ?? styles.first ?? .fallback
  }

  /// `&HAABBGGRR`, with or without the alpha byte and trailing `&`, or a plain
  /// decimal as older SSA files write it. Alpha counts transparency.
  static func color(_ text: String) -> UmbelColor? {
    var body = text.trimmingCharacters(in: .whitespaces)
    let value: UInt32?
    if body.uppercased().hasPrefix("&H") {
      body.removeFirst(2)
      body = body.trimmingCharacters(in: CharacterSet(charactersIn: "&"))
      value = UInt32(body, radix: 16)
    } else {
      value = UInt32(body)
    }
    guard let value else { return nil }
    return UmbelColor(
      red: Double(value & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double((value >> 16) & 0xFF) / 255,
      alpha: Double(255 - ((value >> 24) & 0xFF)) / 255)
  }

  /// SSA numbered alignment 1–3 bottom, then +4 for top and +8 for middle.
  static func legacyAlignment(_ value: Int) -> UmbelSubtitleAlignment? {
    switch value {
    case 1...3: return UmbelSubtitleAlignment(rawValue: value)
    case 5...7: return UmbelSubtitleAlignment(rawValue: value + 2)
    case 9...11: return UmbelSubtitleAlignment(rawValue: value - 5)
    default: return nil
    }
  }

  private static func style(
    _ value: String, format: [String], legacyAlignment: Bool
  ) -> ASSStyle {
    let fields = value.split(
      separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false
    ).map { $0.trimmingCharacters(in: .whitespaces) }
    var columns: [String: String] = [:]
    for (name, field) in zip(format, fields) { columns[name] = field }

    let fallback = ASSStyle.fallback
    func number(_ key: String) -> Double? { columns[key].flatMap(Double.init) }
    // ASS writes true as -1; any non-zero value counts.
    func flag(_ key: String, _ otherwise: Bool) -> Bool {
      columns[key].flatMap(Int.init).map { $0 != 0 } ?? otherwise
    }

    var alignment = fallback.alignment
    if let raw = columns["alignment"].flatMap(Int.init) {
      let mapped = legacyAlignment
        ? Self.legacyAlignment(raw) : UmbelSubtitleAlignment(rawValue: raw)
      alignment = mapped ?? alignment
    }

    return ASSStyle(
      name: columns["name"] ?? fallback.name,
      fontName: columns["fontname"] ?? fallback.fontName,
      fontSize: number("fontsize") ?? fallback.fontSize,
      primaryColor: columns["primarycolour"].flatMap(color) ?? fallback.primaryColor,
      outlineColor: columns["outlinecolour"].flatMap(color) ?? fallback.outlineColor,
      isBold: flag("bold", fallback.isBold),
      isItalic: flag("italic", fallback.isItalic),
      isUnderlined: flag("underline", fallback.isUnderlined),
      isStruckThrough: flag("strikeout", fallback.isStruckThrough),
      outlineWidth: number("outline") ?? fallback.outlineWidth,
      alignment: alignment,
      marginLeft: number("marginl") ?? fallback.marginLeft,
      marginRight: number("marginr") ?? fallback.marginRight,
      marginVertical: number("marginv") ?? fallback.marginVertical)
  }
}
