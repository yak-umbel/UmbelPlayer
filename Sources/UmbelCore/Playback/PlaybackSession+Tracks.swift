extension PlaybackSession {
  /// The audio track chosen; nil if none.
  public var selectedAudioTrack: UmbelTrack.ID? { audioTrack?.id }
  /// How the chosen audio track plays; see `UmbelObjectAudioMode`.
  public var audioRoute: UmbelAudioRoute { get async { await audio.route } }
  /// The subtitle track chosen; nil if none.
  public var selectedSubtitleTrack: UmbelTrack.ID? {
    get async { await subtitles.selectedTrack?.id }
  }
}
