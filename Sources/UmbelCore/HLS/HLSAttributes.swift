import Foundation

/// A playlist tag's attribute list: `NAME=value,NAME="quoted, with commas"`.
/// Split on commas outside quotes; quoted values are unquoted.
internal enum HLSAttributes {
  static func parse(_ list: String) -> [String: String] {
    var attributes: [String: String] = [:]
    var name = ""
    var value = ""
    var inValue = false
    var inQuotes = false
    func finish() {
      let key = name.trimmingCharacters(in: .whitespaces)
      if !key.isEmpty { attributes[key] = value.trimmingCharacters(in: .whitespaces) }
      name = ""
      value = ""
      inValue = false
    }
    for character in list {
      switch character {
      case "\"":
        inQuotes.toggle()
      case "," where !inQuotes:
        finish()
      case "=" where !inValue && !inQuotes:
        inValue = true
      default:
        if inValue { value.append(character) } else { name.append(character) }
      }
    }
    finish()
    return attributes
  }

  /// Relative to `base`. Spaces and other characters sites leave unescaped
  /// are escaped first, when the address will not parse as it stands.
  static func resolve(_ reference: String, against base: URL) -> URL? {
    if let url = URL(string: reference, relativeTo: base) { return url.absoluteURL }
    let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#"))
    let escaped = reference.addingPercentEncoding(withAllowedCharacters: allowed) ?? reference
    return URL(string: escaped, relativeTo: base)?.absoluteURL
  }

  /// A line's tag and what follows its colon.
  static func split(_ line: String) -> (tag: String, value: String) {
    guard let colon = line.firstIndex(of: ":") else { return (line, "") }
    return (String(line[..<colon]), String(line[line.index(after: colon)...]))
  }

  /// A playlist's lines: trimmed, without blank ones or a byte order mark.
  static func lines(of text: String) -> [String] {
    text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(["\u{FEFF}"])) }
      .filter { !$0.isEmpty }
  }
}
