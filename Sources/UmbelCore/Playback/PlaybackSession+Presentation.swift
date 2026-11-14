import CoreGraphics
import Foundation

extension PlaybackSession {
  /// Presents the frame due now. Driven by the host's display loop — the
  /// core holds no display link; see `VideoRenderer`. Subtitles are drawn
  /// into it unless the session was built with `compositesSubtitles: false`.
  ///
  /// The frame says which seek it follows, by `seekGeneration`: one with the
  /// generation `seekGeneration` has after `seek(to:)` returns, or higher, is
  /// the picture of that seek, wherever the clock stands.
  public func renderVideoFrame() async throws -> PresentedFrame? {
    try await presentVideoFrame()
  }

  /// The first picture presented since the session started or the latest
  /// seek began; nil until one is. Whoever drives the display loop, this is
  /// how a host asks whether the picture of its seek is up: it is once
  /// `firstPresentedFrame?.seekGeneration` is `seekGeneration` read after
  /// `seek(to:)` returned. That is the renderer's presentation call, handed
  /// the picture to show, not the display having shown it. Works paused: it
  /// goes by the seek, not by the clock.
  public var firstPresentedFrame: PresentedFrame? { pictureSignal.first }

  /// Every presentation goes through here, the session's own refreshes too,
  /// so that a picture one of them takes is not lost to the signal.
  func presentVideoFrame() async throws -> PresentedFrame? {
    let askedAt = pictureSignal.settled
    do {
      guard let frame = try await presenter.renderVideoFrame(videoSize: videoSize) else { return nil }
      return pictureSignal.presented(frame, askedAt: askedAt, latest: seekGeneration)
    } catch {
      if try await recoverVideoOutputFailure(error) { return nil }
      throw error
    }
  }


  /// Width over height, or nil for the source's own shape.
  public var aspectRatio: Double? { presentation.aspectRatio }
  public var pictureScaling: UmbelPictureScaling { presentation.scaling }
  /// Seconds subtitles come later; negative, earlier.
  public var subtitleDelay: TimeInterval { presentation.subtitleDelay }
  /// Times the authored subtitle size.
  public var subtitleScale: Double { presentation.subtitleScale }
  /// Seconds sound comes later than the picture; negative, earlier.
  public var audioDelay: TimeInterval { presentation.audioDelay }
  /// Picture location in fractions of the view, including cropped edges.
  public var pictureFrame: CGRect? {
    get async { await (presenter.renderer as? any PictureFrameReporting)?.normalizedPictureFrame }
  }

  public func setAspectRatio(_ ratio: Double?) async {
    if let ratio, !(ratio.isFinite && ratio > 0) { return }
    presentation.aspectRatio = ratio
    await applyGeometry()
  }

  public func setPictureScaling(_ scaling: UmbelPictureScaling) async {
    presentation.scaling = scaling
    await applyGeometry()
  }

  public func setSubtitleDelay(_ seconds: TimeInterval) async {
    await setSubtitleDelay(seconds, for: .primary)
  }

  public func setSubtitleScale(_ scale: Double) async {
    await setSubtitleScale(scale, for: .primary)
  }

  /// Applies to subsequently processed audio, without seeking or changing
  /// playback state. Prepared sound may take a short time to drain first. Increasing
  /// delay can insert silence; decreasing it can skip sound at the transition.
  public func setAudioDelay(_ seconds: TimeInterval) async {
    guard seconds.isFinite else { return }
    let value = min(max(seconds, PresentationSettings.audioDelays.lowerBound),
                    PresentationSettings.audioDelays.upperBound)
    guard value != presentation.audioDelay else { return }
    presentation.audioDelay = value
    await audio.setAudioDelay(presentation.audioDelayTime)
    guard let pipeline else { return }
    await pipeline.setAudioDelay(presentation.audioDelayTime)
  }

  /// Captures the last picture shown, with subtitles unless excluded.
  public func snapshot(includingSubtitles: Bool = true) async throws -> CGImage {
    if await videoCapabilities.snapshot == .unsupported(.systemDisplay) {
      throw UmbelError.snapshotUnavailable(reason: "the picture is only shown by the system")
    }
    guard let provider = presenter.renderer as? any SnapshotFrameProviding,
          let frame = await provider.snapshotFrame else {
      throw UmbelError.snapshotUnavailable(reason: "no picture shown yet")
    }
    guard frame.pixelBuffer != nil, !frame.presentationRoute.isSystem else {
      throw UmbelError.snapshotUnavailable(reason: "the picture is only shown by the system")
    }
    guard let device = await provider.snapshotDevice?.device else {
      throw UmbelError.snapshotUnavailable(reason: "the renderer cannot capture pictures")
    }
    let size = PictureFit.shape(of: frame.displaySize, aspectRatio: presentation.aspectRatio)
    let bitmaps = includingSubtitles
      ? await subtitles.snapshot(
          at: presenter.clock.now(), in: size,
          videoSize: frame.orientedPixelSize) : []
    return try FrameSnapshot.image(
      of: frame, size: size, subtitles: bitmaps, device: device,
      adjustments: presentation.videoAdjustments, diagnostics: diagnostics)
  }

  private func applyGeometry() async {
    await presenter.renderer?.setPictureGeometry(
      aspectRatio: presentation.aspectRatio, scaling: presentation.scaling)
  }
}
