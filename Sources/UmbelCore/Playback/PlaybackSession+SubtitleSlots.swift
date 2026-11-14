import Foundation

extension PlaybackSession {
  /// Selects one subtitle layer. Selecting nil disables only that layer.
  /// Secondary selection is explicit; automatic forced selection affects primary only.
  public func selectSubtitleTrack(_ id: UmbelTrack.ID?, for slot: UmbelSubtitleSlot) async throws {
    guard !isStopped else { return }
    let revision = await subtitles.replayRevision
    try await subtitles.selectManually(id, for: slot)
    guard !isStopped else { return }
    await pushRouting()
    try await recoverSubtitleCoverage(since: revision)
    _ = try? await presentVideoFrame()
  }

  public func selectedSubtitleTrack(for slot: UmbelSubtitleSlot) async -> UmbelTrack.ID? {
    await subtitles.selectedTrack(for: slot)?.id
  }

  public func currentSubtitleCues(for slot: UmbelSubtitleSlot) async -> [UmbelSubtitleCue] {
    await subtitles.cues(atClock: presenter.clock.now(), for: slot)
  }

  public func subtitleDelay(for slot: UmbelSubtitleSlot) async -> TimeInterval {
    await subtitles.delay(for: slot)
  }

  public func subtitleScale(for slot: UmbelSubtitleSlot) async -> Double {
    await subtitles.scale(for: slot)
  }

  public func subtitlePlacement(for slot: UmbelSubtitleSlot) async -> UmbelSubtitlePlacement {
    await subtitles.placement(for: slot)
  }

  /// Seconds this layer appears later; negative values display it earlier.
  public func setSubtitleDelay(_ seconds: TimeInterval, for slot: UmbelSubtitleSlot) async {
    guard seconds.isFinite else { return }
    let revision = await subtitles.replayRevision
    if slot == .primary { presentation.subtitleDelay = seconds }
    await subtitles.setDelay(seconds, for: slot)
    try? await recoverSubtitleCoverage(since: revision)
    _ = try? await presentVideoFrame()
  }

  /// Multiplier of authored size, clamped to the supported subtitle size range.
  public func setSubtitleScale(_ scale: Double, for slot: UmbelSubtitleSlot) async {
    guard scale.isFinite else { return }
    let value = min(max(scale, PresentationSettings.subtitleScales.lowerBound),
                    PresentationSettings.subtitleScales.upperBound)
    if slot == .primary { presentation.subtitleScale = value }
    await subtitles.setScale(value, for: slot)
    _ = try? await presentVideoFrame()
  }

  /// Placement in fractions of canvas height. Secondary defaults to 0.2 upward.
  public func setSubtitlePlacement(
    _ placement: UmbelSubtitlePlacement, for slot: UmbelSubtitleSlot
  ) async {
    guard placement.verticalOffset.isFinite, placement.bottomInset.isFinite else { return }
    guard await subtitles.setPlacement(placement.normalized, for: slot) else { return }
    _ = try? await presentVideoFrame()
  }
}
