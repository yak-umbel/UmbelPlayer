extension PlaybackSession {
  /// Sets how loud it plays: 0 silent, 1 as recorded; held to that range,
  /// and a value that is not a number is left out. It stays through track
  /// switches, seeks and a replaced system renderer; set before loading,
  /// from the start.
  public func setVolume(_ volume: Float) async {
    guard volume.isFinite else { return }
    self.volume = min(max(volume, 0), 1)
    await applyLevel()
  }

  /// Mutes or unmutes; the volume is kept for when it is unmuted.
  public func setMuted(_ muted: Bool) async {
    isMuted = muted
    await applyLevel()
  }

  /// Hands the level to whatever plays the sound, which keeps it.
  func applyLevel() async {
    await audio.setLevel(volume: volume, muted: isMuted)
  }
}
