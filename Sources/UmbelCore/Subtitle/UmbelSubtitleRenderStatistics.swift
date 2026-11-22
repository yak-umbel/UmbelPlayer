import Foundation

/// What drawing ASS subtitles has cost a session so far, across every track
/// it has shown.
///
/// For a host's diagnostics: a picture that stays on screen is drawn once
/// however often the display asks for it, so a count that climbs with the
/// display rate, or a long longest drawing, says where a slowdown is.
public struct UmbelSubtitleRenderStatistics: Sendable, Equatable {
  /// Times libass was asked to draw a picture.
  public let renderCount: Int
  /// The longest single drawing, in seconds.
  public let longestRender: TimeInterval
  /// Glyph lookups libass gave up on: characters that no font it can use
  /// covers, which show as empty boxes or nothing. Each drawing of such a
  /// line counts again. Zero when every character was drawn. A font given
  /// through `PlaybackSession.setSubtitleFonts(_:)` is what fixes it.
  public let unresolvedGlyphCount: Int

  public static let none = UmbelSubtitleRenderStatistics(
    renderCount: 0, longestRender: 0, unresolvedGlyphCount: 0)
}
