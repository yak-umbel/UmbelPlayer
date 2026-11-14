import CoreGraphics
import Foundation

/// Where each rendered cue goes on the picture.
///
/// Pure geometry, kept apart from drawing so it can be checked without fonts.
internal enum SubtitleLayout {
  struct Item {
    var alignment: UmbelSubtitleAlignment
    /// Margins in pixels, measured to the text.
    var left: CGFloat
    var right: CGFloat
    var vertical: CGFloat
    /// The bitmap, padding included.
    var size: CGSize
    /// Transparent border around the text, there to hold the outline. The
    /// margins place the text, so the bitmap starts this much further out.
    var padding: CGFloat
  }

  /// Frames in the order given, top-left origin.
  ///
  /// A cue that would overlap one already placed moves away from its edge —
  /// up from the bottom, down from the top — until it is clear, which is how
  /// libass resolves collisions. Earlier cues keep the base position.
  static func place(_ items: [Item], in canvas: CGSize) -> [CGRect] {
    var placed: [CGRect] = []
    for item in items {
      var frame = CGRect(origin: basePosition(of: item, in: canvas), size: item.size)
      let movesUp = item.alignment.vertical == .bottom
      // Bounded: each step clears one rectangle, so at most one per placed cue.
      for _ in 0...placed.count {
        guard let blocker = placed.first(where: { $0.intersects(frame) }) else { break }
        frame.origin.y = movesUp ? blocker.minY - frame.height : blocker.maxY
      }
      placed.append(clamped(frame, to: canvas))
    }
    return placed
  }

  private static func basePosition(of item: Item, in canvas: CGSize) -> CGPoint {
    let width = item.size.width
    let height = item.size.height
    let pad = item.padding

    let x: CGFloat
    switch item.alignment.horizontal {
    case .left:
      x = item.left - pad
    case .right:
      x = canvas.width - item.right - width + pad
    case .center:
      // Centred between the margins, as ASS does, not on the whole picture.
      x = item.left + (canvas.width - item.left - item.right - width) / 2
    }

    let y: CGFloat
    switch item.alignment.vertical {
    case .bottom: y = canvas.height - item.vertical - height + pad
    case .top: y = item.vertical - pad
    case .middle: y = (canvas.height - height) / 2
    }
    return CGPoint(x: x, y: y)
  }

  /// Keeps a cue on the picture where it fits; one larger than the picture is
  /// pinned to the top-left rather than pushed off entirely.
  private static func clamped(_ frame: CGRect, to canvas: CGSize) -> CGRect {
    var result = frame
    result.origin.x = max(0, min(result.origin.x, canvas.width - result.width))
    result.origin.y = max(0, min(result.origin.y, canvas.height - result.height))
    return result
  }
}
