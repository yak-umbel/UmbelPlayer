import Foundation

/// Fonts a host gives the player for ASS subtitles.
///
/// A script names the fonts it was written for, and libass replaces one the
/// device does not have with another. It can only draw from font files it
/// reads itself, so where the system has none that covers a script's
/// characters, a line comes out as empty boxes, and drawing it again and
/// again is slow. Fonts given here are what libass falls back to.
public struct UmbelSubtitleFonts: Sendable, Equatable {
  /// Font files, as they sit on disk: TrueType, OpenType, or a collection of
  /// either. libass reads each one's family names from the file.
  public var fonts: [Data]
  /// The family libass uses for a line whose own font is missing, the one
  /// of the fonts above that should cover the characters of the subtitles.
  /// Nil leaves the platform's default, which is a Latin font.
  public var defaultFamily: String?

  public init(fonts: [Data] = [], defaultFamily: String? = nil) {
    self.fonts = fonts
    self.defaultFamily = defaultFamily
  }
}
