import CoreMedia
import Foundation

/// Mutable state confined to SubtitleController's actor, one instance per slot.
internal final class SubtitleSlotState {
  var track: UmbelTrack?
  var decoder: SubtitleDecodeSession?
  var externalASS: ASSSubtitleSource?
  let textRenderer = UmbelSubtitleRenderer()
  var delaySeconds: TimeInterval = 0
  var delay: CMTime { CMTime(seconds: delaySeconds, preferredTimescale: 1_000_000) }
  var scale = 1.0
  var placement: UmbelSubtitlePlacement
  /// Invalidates a pending selection before it can commit across an await.
  var selectionGeneration = 0
  /// Last embedded source/offset change, in the controller's replay revision.
  var replayRevision = 0

  init(placement: UmbelSubtitlePlacement = .init()) {
    self.placement = placement
  }
}
