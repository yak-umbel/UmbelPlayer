import Foundation

extension PlaybackSession {
  /// Subtitle placement in fractions of the visible video canvas height.
  public var subtitlePlacement: UmbelSubtitlePlacement {
    get async { await subtitles.placement }
  }

  /// Changes the composed group's position and requests a redraw, including
  /// when playback is paused. Non-finite values are ignored; finite values
  /// are clamped to -1...1 for offset and 0...1 for bottom inset.
  public func setSubtitlePlacement(_ placement: UmbelSubtitlePlacement) async {
    await setSubtitlePlacement(placement, for: .primary)
  }
}
