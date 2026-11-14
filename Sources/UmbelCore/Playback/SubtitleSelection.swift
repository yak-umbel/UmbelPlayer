import Foundation

/// Which subtitle track shows when the host has not chosen one.
///
/// Only forced tracks, and only in the language being heard. Forced subtitles
/// carry dialogue itself — the foreign-language lines of a film — so leaving
/// them off leaves content out. Ordinary tracks stay off even when flagged
/// default: whether to read subtitles is the viewer's call.
internal enum SubtitleSelection {
  /// The forced subtitle track in the audio track's language, if any.
  static func forcedTrack(for audio: UmbelTrack?, in tracks: [UmbelTrack]) -> UmbelTrack? {
    guard let language = normalizedLanguage(audio?.language) else { return nil }
    return tracks.first {
      $0.kind == .subtitle && $0.isForced && normalizedLanguage($0.language) == language
    }
  }

  /// One spelling per language: bibliographic and terminological ISO 639-2
  /// codes, two-letter codes and region-tagged forms all reduce to the same
  /// base. MKV writes `chi`, MP4 `zho`, newer files `zh-CN` — without this
  /// they never match. Nil for codes that name no language.
  static func normalizedLanguage(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    let canonical = Locale.canonicalLanguageIdentifier(from: code).lowercased()
    guard let base = canonical.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
          !notALanguage.contains(String(base)) else { return nil }
    return String(base)
  }

  /// ISO 639-2 codes for "undetermined", "multiple", "no linguistic content"
  /// and "uncoded".
  private static let notALanguage: Set<String> = ["und", "mul", "zxx", "mis"]
}
