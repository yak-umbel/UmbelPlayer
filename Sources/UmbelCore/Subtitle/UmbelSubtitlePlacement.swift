import CoreGraphics
import Foundation

/// Moves the composed subtitle group within the visible video canvas.
///
/// Both values are fractions of the canvas height. A positive vertical offset
/// moves subtitles upward. The bottom inset reserves that fraction of the
/// canvas below the group. The default leaves authored positions untouched,
/// including artwork with an explicit position.
public struct UmbelSubtitlePlacement: Equatable, Sendable {
  public let verticalOffset: Double
  public let bottomInset: Double

  public init(verticalOffset: Double = 0, bottomInset: Double = 0) {
    self.verticalOffset = verticalOffset
    self.bottomInset = bottomInset
  }

  internal var normalized: Self {
    Self(verticalOffset: min(max(verticalOffset, -1), 1),
         bottomInset: min(max(bottomInset, 0), 1))
  }

  /// Translate every image equally, keeping authored spacing and alignment.
  /// When the group cannot fit above the bottom inset, its top is anchored at
  /// the canvas top so no relative position is lost.
  internal func apply(to bitmaps: [UmbelSubtitleBitmap], in size: CGSize) -> [UmbelSubtitleBitmap] {
    guard (verticalOffset != 0 || bottomInset != 0), !bitmaps.isEmpty,
          size.height.isFinite, size.height > 0 else { return bitmaps }
    let bounds = bitmaps.map(\.frame).reduce(CGRect.null) { $0.union($1) }
    guard !bounds.isNull, bounds.minY.isFinite, bounds.maxY.isFinite else { return bitmaps }

    let safeBottom = size.height * (1 - bottomInset)
    let shift: CGFloat
    if bounds.height > safeBottom {
      shift = -bounds.minY
    } else {
      let desired = -CGFloat(verticalOffset) * size.height
      shift = min(max(desired, -bounds.minY), safeBottom - bounds.maxY)
    }
    guard shift != 0 else { return bitmaps }
    return bitmaps.map { bitmap in
      UmbelSubtitleBitmap(
        image: bitmap.image,
        frame: bitmap.frame.offsetBy(dx: 0, dy: shift))
    }
  }
}
