import CoreGraphics
import Foundation

extension PlaybackSession {
  /// Subtitle cues showing now, queried by the host's display loop.
  public var currentSubtitleCues: [UmbelSubtitleCue] {
    get async { await presenter.currentSubtitleCues }
  }

  /// Chooses a subtitle track; nil turns subtitles off.
  ///
  /// Embedded tracks catch up from retained packets. Missing history on a
  /// seekable source is read again at the current position. External tracks
  /// were loaded whole and show at once.
  public func selectSubtitleTrack(_ id: UmbelTrack.ID?) async throws {
    try await selectSubtitleTrack(id, for: .primary)
  }

  /// The subtitles showing now, drawn and positioned for a picture of
  /// `size` pixels — the picture as displayed, not the view around it.
  ///
  /// ASS tracks are drawn by libass, with their full effects; other text
  /// tracks by CoreText; bitmap tracks come as they are. Asked every frame,
  /// it redraws only when the picture changes: `isChanged` says whether the
  /// host needs to update anything.
  ///
  /// For a session built with `compositesSubtitles: false`. With it on, the
  /// renderer asks the same question at its own size, and the two would
  /// keep undoing each other's "unchanged".
  public func renderSubtitles(in size: CGSize) async -> UmbelSubtitleFrame {
    await presenter.renderSubtitles(in: size, videoSize: videoSize)
  }

  /// The video's own resolution as it is shown: turned a quarter, width and
  /// height trade places.
  var videoSize: CGSize? {
    videoTrack?.video.map {
      $0.appliedRotation.turned(CGSize(width: $0.width, height: $0.height))
    }
  }

  /// Adds a subtitle file from outside the container — a sidecar `.srt`,
  /// `.ass` or `.vtt` — and returns its track. It is read whole, converted to
  /// UTF-8 from whatever it was written in, and not selected: pass the track
  /// to `selectSubtitleTrack(_:)` to show it.
  public func addExternalSubtitle(
    _ source: any UmbelSource, language: String? = nil, title: String? = nil
  ) async throws -> UmbelTrack {
    try await subtitles.addExternal(source, language: language, title: title)
  }

  /// Hands subtitle choice back to the player: forced subtitles in the audio
  /// language show, nothing else does.
  public func selectSubtitleTrackAutomatically() async throws {
    guard !isStopped else { return }
    let revision = await subtitles.replayRevision
    try await subtitles.selectAutomatically(audio: audioTrack)
    guard !isStopped else { return }
    await pushRouting()
    try await recoverSubtitleCoverage(since: revision)
    _ = try? await presentVideoFrame()
  }
}
