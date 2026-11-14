import CoreGraphics
import Foundation

/// A rendered subtitle: an image and where it goes on the picture.
///
/// The frame is in the pixel space of the size passed to the renderer, origin
/// top-left. Positioned images rather than one picture-sized image, because
/// bitmap subtitles and libass both produce exactly this, and whatever
/// composites subtitles then needs only one path.
///
/// **The image is scaled to fill the frame.** Drawn text already has the
/// frame's size; a bitmap subtitle keeps the pixels it was authored with.
public struct UmbelSubtitleBitmap: @unchecked Sendable {
  /// Premultiplied alpha. `CGImage` is immutable, which is what makes sharing
  /// it across isolation domains safe.
  public let image: CGImage
  public let frame: CGRect
}

/// What `UmbelSubtitleRenderer.render` returns.
public struct UmbelSubtitleFrame: Sendable {
  public let bitmaps: [UmbelSubtitleBitmap]
  /// False when the input matched the previous call and `bitmaps` are the
  /// very same images; the host can skip updating its layers.
  public let isChanged: Bool
}

/// Lays subtitle cues out with CoreText and returns them as positioned images.
/// Bitmap cues are placed as they are, by their fractions of the picture.
///
/// **Pass the size of the picture as displayed, in pixels** — not the size of
/// the view holding it. Sizes and margins are fractions of the picture; with
/// the view's size, letterboxed video would get oversized text sitting in the
/// black bars.
///
/// It remembers the last input and returns the same images while it repeats,
/// as libass's change detection does. A display loop asks every frame, and
/// laying text out sixty times a second for a line that shows for three
/// seconds is pure waste.
///
/// Not `Sendable`: it holds that cache. Keep it in one isolation domain.
public final class UmbelSubtitleRenderer {
  private var lastCues: [UmbelSubtitleCue] = []
  private var lastSize: CGSize = .zero
  private var lastPicture: CGRect?
  private var lastScale = 1.0
  private var lastBitmaps: [UmbelSubtitleBitmap] = []

  public init() {}

  /// `picture` is where the whole picture is in the canvas — the canvas
  /// itself when nil, as when the picture fits the view. Bitmap cues are
  /// placed on the picture and moved into the canvas where they fall
  /// outside it; text is laid out on the canvas. `scale` enlarges both:
  /// text by its font size, bitmaps from the edge they are near.
  public func render(
    _ cues: [UmbelSubtitleCue], in size: CGSize, picture: CGRect? = nil, scale: Double = 1
  ) -> UmbelSubtitleFrame {
    if cues == lastCues, size == lastSize, picture == lastPicture, scale == lastScale {
      return UmbelSubtitleFrame(bitmaps: lastBitmaps, isChanged: false)
    }
    let bitmaps = Self.draw(cues, in: size, picture: picture, scale: scale)
    lastCues = cues
    lastSize = size
    lastPicture = picture
    lastScale = scale
    lastBitmaps = bitmaps
    return UmbelSubtitleFrame(bitmaps: bitmaps, isChanged: true)
  }

  private static func draw(
    _ cues: [UmbelSubtitleCue], in size: CGSize, picture: CGRect?, scale: Double
  ) -> [UmbelSubtitleBitmap] {
    guard size.width >= 1, size.height >= 1 else { return [] }
    let canvas = CGRect(origin: .zero, size: size)
    let whole = picture ?? canvas
    let pictures = cues.compactMap(\.image).map { image in
      UmbelSubtitleBitmap(
        image: image.image,
        frame: placed(image.relativeFrame, on: whole, scale: scale, within: canvas))
    }
    return pictures + drawText(cues.filter { $0.image == nil }, in: size, scale: scale)
  }

  /// A bitmap cue's frame: its fractions of the picture, enlarged from the
  /// edge it is near — bottom in the lower half, top in the upper — then
  /// moved into the canvas as far as it has to be.
  static func placed(_ relative: CGRect, on picture: CGRect, scale: Double, within canvas: CGRect) -> CGRect {
    let base = CGRect(
      x: picture.minX + relative.minX * picture.width,
      y: picture.minY + relative.minY * picture.height,
      width: relative.width * picture.width, height: relative.height * picture.height)
    let width = base.width * scale
    let height = base.height * scale
    let lower = base.midY > picture.midY
    var frame = CGRect(
      x: base.midX - width / 2, y: lower ? base.maxY - height : base.minY,
      width: width, height: height)
    if frame.maxX > canvas.maxX { frame.origin.x = canvas.maxX - frame.width }
    if frame.minX < canvas.minX { frame.origin.x = canvas.minX }
    if frame.maxY > canvas.maxY { frame.origin.y = canvas.maxY - frame.height }
    if frame.minY < canvas.minY { frame.origin.y = canvas.minY }
    return frame
  }

  private static func drawText(
    _ cues: [UmbelSubtitleCue], in size: CGSize, scale: Double
  ) -> [UmbelSubtitleBitmap] {
    let rendered = cues.compactMap { cue in
      SubtitleRasterizer.rasterize(cue, in: size, scale: scale).map { (cue, $0) }
    }
    let frames = SubtitleLayout.place(
      rendered.map { cue, raster in
        SubtitleLayout.Item(
          alignment: cue.alignment,
          left: cue.margins.left * size.width,
          right: cue.margins.right * size.width,
          vertical: cue.margins.vertical * size.height,
          size: CGSize(width: raster.image.width, height: raster.image.height),
          padding: raster.padding)
      },
      in: size)
    return zip(rendered, frames).map { UmbelSubtitleBitmap(image: $0.1.image, frame: $1) }
  }
}
