import CoreGraphics
import CoreMedia
import Foundation

/// What the host's display loop asks for: the picture now, with subtitles
/// drawn into it, or the subtitles alone for a host drawing them itself.
///
/// Split from the session, which decides what plays; this only answers what
/// shows. It holds nothing that changes: the clock and the subtitle
/// controller keep their own state.
internal struct PlaybackPresenter: Sendable {
  let renderer: (any VideoRenderer)?
  let clock: PresentationClock
  let subtitles: SubtitleController
  /// On: subtitles go into the picture, so they are in it wherever it goes.
  /// Off: the host draws them from `renderSubtitles(in:videoSize:)`.
  let compositesSubtitles: Bool

  /// The frame due now. Subtitles are handed to the renderer first, and
  /// only when they changed; the renderer draws them with the frame.
  func renderVideoFrame(videoSize: CGSize?) async throws -> PresentedFrame? {
    guard let renderer else { return nil }
    let now = await clock.now()
    if compositesSubtitles {
      let canvas = await renderer.subtitleCanvasSize
      let picture = await renderer.subtitlePictureFrame
      let drawn = await subtitles.render(at: now, in: canvas, picture: picture, videoSize: videoSize)
      if drawn.isChanged { await renderer.setSubtitles(drawn.bitmaps) }
    }
    return try await renderer.presentFrame(at: now)
  }

  func renderSubtitles(in size: CGSize, videoSize: CGSize?) async -> UmbelSubtitleFrame {
    await subtitles.render(
      at: await clock.now(), in: size, picture: CGRect(origin: .zero, size: size), videoSize: videoSize)
  }

  var currentSubtitleCues: [UmbelSubtitleCue] {
    get async { await subtitles.cues(atClock: clock.now()) }
  }
}
