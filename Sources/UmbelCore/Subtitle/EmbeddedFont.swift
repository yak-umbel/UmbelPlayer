import Foundation
import UmbelFFmpegSupport

/// A font shipped inside the media, such as a Matroska attachment.
///
/// Styled subtitles are often written for fonts that are nowhere on the
/// viewer's device, so the file carries them; without these, signs and
/// karaoke fall back to a system font and lose their look.
internal struct EmbeddedFont: Sendable {
  let name: String
  let data: Data

  /// The fonts among a container's attachments.
  ///
  /// By MIME type first, but muxers disagree on which type a font gets, so
  /// the file extension decides when the type does not. Anything else —
  /// cover art, say — is left out.
  static func fonts(from attachments: [FFmpegAttachment]) -> [EmbeddedFont] {
    attachments.compactMap { attachment in
      let name = attachment.filename ?? "attachment"
      guard isFont(mimeType: attachment.mimeType, filename: attachment.filename) else { return nil }
      return EmbeddedFont(name: name, data: attachment.data)
    }
  }

  private static func isFont(mimeType: String?, filename: String?) -> Bool {
    if let mimeType, fontTypes.contains(mimeType.lowercased()) { return true }
    guard let filename else { return false }
    return fontExtensions.contains((filename as NSString).pathExtension.lowercased())
  }

  private static let fontTypes: Set<String> = [
    "font/ttf", "font/otf", "font/sfnt", "font/collection",
    "application/x-truetype-font", "application/x-font-ttf", "application/x-font-otf",
    "application/x-font", "application/font-sfnt", "application/vnd.ms-opentype",
  ]
  private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]
}
