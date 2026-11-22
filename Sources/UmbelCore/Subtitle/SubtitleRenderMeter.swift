import Foundation
import UmbelASSSupport

/// Adds up what libass's drawings cost, for one session.
///
/// Each ASS source is an actor of its own and the controller reads the
/// total from outside them, so the sums sit behind a lock. The meter belongs
/// to the controller, not to a source: a track that is switched away from
/// leaves its drawings in the total.
internal final class SubtitleRenderMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var renderCount = 0
  private var longestRender: TimeInterval = 0
  private var unresolvedGlyphCount = 0

  func record(_ frame: ASSFrame) {
    lock.withLock {
      renderCount += 1
      longestRender = max(longestRender, frame.renderDuration)
      unresolvedGlyphCount += frame.unresolvedGlyphCount
    }
  }

  var statistics: UmbelSubtitleRenderStatistics {
    lock.withLock {
      UmbelSubtitleRenderStatistics(
        renderCount: renderCount, longestRender: longestRender,
        unresolvedGlyphCount: unresolvedGlyphCount)
    }
  }
}
