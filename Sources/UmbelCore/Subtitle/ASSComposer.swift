import CoreGraphics
import Foundation
import UmbelASSSupport

/// Turns libass's coverage masks into positioned premultiplied bitmaps — the
/// same shape the CoreText path produces.
///
/// Masks that touch are composited together; masks that do not stay apart.
/// A sign at the top and dialogue at the bottom then make two small bitmaps
/// instead of one the size of the picture, which matters when an animated
/// line is composited again every frame.
internal enum ASSComposer {
  static func compose(_ images: [ASSImage]) -> [UmbelSubtitleBitmap] {
    groups(of: images).compactMap(composite)
  }

  private static func rect(_ image: ASSImage) -> CGRect {
    CGRect(x: image.x, y: image.y, width: image.width, height: image.height)
  }

  /// Images whose rectangles intersect, directly or through others, form a
  /// group. Order within a group is libass's, which is painting order.
  private static func groups(of images: [ASSImage]) -> [[ASSImage]] {
    var groups: [(bounds: CGRect, members: [Int])] = []
    for (index, image) in images.enumerated() where image.width > 0 && image.height > 0 {
      var bounds = rect(image)
      var members = [index]
      // Absorb every group this one touches; the union may reach more, so
      // repeat until nothing else intersects.
      var merged = true
      while merged {
        merged = false
        if let hit = groups.firstIndex(where: { $0.bounds.intersects(bounds) }) {
          bounds = bounds.union(groups[hit].bounds)
          members += groups[hit].members
          groups.remove(at: hit)
          merged = true
        }
      }
      groups.append((bounds, members))
    }
    return groups.map { group in group.members.sorted().map { images[$0] } }
  }

  /// Source-over in premultiplied BGRA, the layout CoreGraphics and Metal
  /// read natively on Apple hardware.
  private static func composite(_ group: [ASSImage]) -> UmbelSubtitleBitmap? {
    let bounds = group.map(rect).reduce(CGRect.null) { $0.union($1) }
    let width = Int(bounds.width)
    let height = Int(bounds.height)
    guard width > 0, height > 0 else { return nil }
    let originX = Int(bounds.minX)
    let originY = Int(bounds.minY)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    pixels.withUnsafeMutableBufferPointer { out in
      for image in group {
        let red = Int(image.color >> 24)
        let green = Int((image.color >> 16) & 0xFF)
        let blue = Int((image.color >> 8) & 0xFF)
        let opacity = 255 - Int(image.color & 0xFF)
        for row in 0..<image.height {
          let target = ((image.y - originY + row) * width + (image.x - originX)) * 4
          for column in 0..<image.width {
            let alpha = Int(image.coverage[row * image.stride + column]) * opacity / 255
            guard alpha > 0 else { continue }
            let keep = 255 - alpha
            let at = target + column * 4
            out[at] = UInt8((blue * alpha + Int(out[at]) * keep) / 255)
            out[at + 1] = UInt8((green * alpha + Int(out[at + 1]) * keep) / 255)
            out[at + 2] = UInt8((red * alpha + Int(out[at + 2]) * keep) / 255)
            out[at + 3] = UInt8((255 * alpha + Int(out[at + 3]) * keep) / 255)
          }
        }
      }
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    return UmbelSubtitleBitmap(image: image, frame: bounds)
  }
}
