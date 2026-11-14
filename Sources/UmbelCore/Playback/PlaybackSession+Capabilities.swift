import Foundation

extension PlaybackSession {
  /// Current content/output capabilities. No active video reports `noVideo`.
  /// Settings may still be stored while unsupported and applied to a later route.
  public var videoCapabilities: UmbelVideoCapabilities {
    get async {
      guard !isStopped, pipeline != nil, videoTrack != nil, let renderer = presenter.renderer else {
        return UmbelVideoCapabilities(canOverrideAspectRatio: false, canScalePicture: false,
                                      snapshot: .unsupported(.noVideo))
      }
      return await renderer.videoCapabilities
    }
  }
}
