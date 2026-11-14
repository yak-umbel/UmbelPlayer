extension PlaybackSession {
  /// Retained even when the current output cannot adjust its pixels.
  public var videoAdjustments: UmbelVideoAdjustments { presentation.videoAdjustments }

  /// Updates the video and redraws the paused picture. Subtitles keep their colors.
  public func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async {
    guard adjustments != presentation.videoAdjustments else { return }
    presentation.videoAdjustments = adjustments
    await presenter.renderer?.setVideoAdjustments(adjustments)
    _ = try? await presentVideoFrame()
  }
}
