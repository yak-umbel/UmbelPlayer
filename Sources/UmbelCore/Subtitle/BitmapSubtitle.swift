import CoreGraphics
import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Turns a decoded bitmap subtitle event into cues.
///
/// Positions become fractions of the canvas the stream was authored on, so
/// the same cue lands in the same place at any picture size — the way text
/// cue sizes are fractions of the picture height.
internal enum BitmapSubtitle {
  /// One cue per picture. `fallbackCanvas` is used when the stream does not
  /// state its canvas; usually the video's size, which is what such streams
  /// are drawn for. Without either nothing can be placed, and nothing is
  /// returned.
  static func cues(
    from subtitle: FFmpegSubtitle, start: CMTime, end: CMTime?, fallbackCanvas: CGSize?
  ) -> [UmbelSubtitleCue] {
    let stated = CGSize(width: subtitle.canvasWidth, height: subtitle.canvasHeight)
    guard let canvas = stated.width > 0 && stated.height > 0 ? stated : fallbackCanvas,
          canvas.width > 0, canvas.height > 0 else { return [] }

    return subtitle.bitmaps.compactMap { bitmap in
      guard let image = image(from: bitmap) else { return nil }
      let frame = CGRect(
        x: Double(bitmap.x) / canvas.width, y: Double(bitmap.y) / canvas.height,
        width: Double(bitmap.width) / canvas.width, height: Double(bitmap.height) / canvas.height)
      return UmbelSubtitleCue(
        start: start, end: end, runs: [],
        image: UmbelSubtitleImage(image: image, relativeFrame: frame))
    }
  }

  /// Premultiplied BGRA bytes as an image, without copying them again.
  private static func image(from bitmap: FFmpegSubtitleBitmap) -> CGImage? {
    guard let provider = CGDataProvider(data: bitmap.pixels as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGImage(
      width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: bitmap.width * 4, space: space,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
