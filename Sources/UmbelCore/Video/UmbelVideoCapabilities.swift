import Foundation

public enum UmbelSubtitlePresentation: String, Sendable, Equatable {
  case composited
  case separateOverlay
  case unavailable
}

/// Why the current route cannot provide a snapshot.
public enum UmbelSnapshotLimitation: String, Sendable, Equatable {
  case noVideo
  case rendererUnsupported
  /// The system owns the displayed pixels; this route has no verified readback.
  case systemDisplay
}

/// A point-in-time observation, not a guarantee that a later capture succeeds.
public enum UmbelSnapshotAvailability: Sendable, Equatable {
  case available
  /// The route supports capture, but has not displayed a picture yet.
  case noFrame
  /// A renderer can capture only with a paused timeline. Query again after pausing.
  case requiresPause
  case unsupported(UmbelSnapshotLimitation)
}

/// Capabilities of the current renderer and content, including before the first frame.
/// Query again after loading, seeking or changing the output route.
public struct UmbelVideoCapabilities: Sendable, Equatable {
  public let canOverrideAspectRatio: Bool
  public let canScalePicture: Bool
  public let canAdjustColors: Bool
  public let snapshot: UmbelSnapshotAvailability
  public internal(set) var subtitles: UmbelSubtitlePresentation = .unavailable

  public init(
    canOverrideAspectRatio: Bool, canScalePicture: Bool,
    snapshot: UmbelSnapshotAvailability, canAdjustColors: Bool = false,
    subtitles: UmbelSubtitlePresentation
  ) {
    self.canOverrideAspectRatio = canOverrideAspectRatio
    self.canScalePicture = canScalePicture
    self.snapshot = snapshot
    self.canAdjustColors = canAdjustColors
    self.subtitles = subtitles
  }

  internal static func pixels(hasFrame: Bool, canScalePicture: Bool = true) -> Self {
    Self(canOverrideAspectRatio: true, canScalePicture: canScalePicture,
         snapshot: hasFrame ? .available : .noFrame, canAdjustColors: true, subtitles: .composited)
  }

  internal static var systemDisplay: Self {
    var result = Self(canOverrideAspectRatio: false, canScalePicture: true,
                      snapshot: .unsupported(.systemDisplay))
    result.subtitles = .unavailable
    return result
  }
}

/// Establishes content-specific limits during preparation, before any frame is queued.
internal protocol VideoRoutePreparing: Actor {
  func setSystemVideoRoute(_ system: Bool) async
  func setVideoPresentationPlan(_ plan: VideoPresentationPlan) async
}

extension VideoRoutePreparing {
  func setVideoPresentationPlan(_ plan: VideoPresentationPlan) async {
    await setSystemVideoRoute(plan.route.isSystem)
  }
}
