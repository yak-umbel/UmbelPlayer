import Foundation

extension PlaybackSession {
  /// The fonts the host has given ASS subtitles; empty until it sets some.
  public var subtitleFonts: UmbelSubtitleFonts {
    get async { await subtitles.hostFonts }
  }

  /// Gives ASS subtitles fonts to draw from, and the family to fall back to.
  ///
  /// Applies to the ASS tracks showing now and to any shown later, so it can
  /// be set before the first one. Fonts add to those a track already has, and
  /// a font cannot be taken back from a track that holds it: set the whole
  /// collection once, early.
  ///
  /// Each track keeps its own copy of the fonts while it is selected, so a
  /// large font costs its size again per ASS track shown.
  public func setSubtitleFonts(_ fonts: UmbelSubtitleFonts) async {
    await subtitles.setHostFonts(fonts)
    _ = try? await presentVideoFrame()
  }

  /// What drawing ASS subtitles has cost this session, across every track.
  /// For a host's diagnostics; reading it changes nothing.
  public var subtitleRenderStatistics: UmbelSubtitleRenderStatistics {
    get async { await subtitles.renderStatistics }
  }
}
