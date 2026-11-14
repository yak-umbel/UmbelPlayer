import Foundation
import LibASS

/// One piece of a rendered frame: a single-colour coverage mask and where it
/// goes. libass draws fills, outlines and shadows as separate pieces.
public struct ASSImage: Sendable, Equatable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int
  /// Bytes per row of `coverage`; at least `width`.
  public let stride: Int
  /// Coverage per pixel, 0...255. Copied: libass reuses its buffers on the
  /// next render.
  public let coverage: [UInt8]
  /// RGBA, the last byte being transparency — 0 is opaque.
  public let color: UInt32
}

/// What one call to `render` produced.
public struct ASSFrame: Sendable {
  public let images: [ASSImage]
  /// False when the picture is the same as the previous call's; the caller
  /// can keep what it composited last time.
  public let isChanged: Bool
}

/// Turns a track into images at a given time.
///
/// Not thread-safe; see `ASSLibrary`.
public final class ASSRenderer: @unchecked Sendable {
  private let pointer: OpaquePointer
  private let library: ASSLibrary

  public init(library: ASSLibrary) {
    self.library = library
    pointer = ass_renderer_init(library.pointer)!
    reloadFonts()
  }

  deinit {
    ass_renderer_done(pointer)
  }

  /// Fonts come from CoreText — no fontconfig on Apple platforms — plus
  /// whatever was added to the library. Call again after adding fonts.
  public func reloadFonts() {
    ass_set_fonts(
      pointer, nil, "sans-serif", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
  }

  /// The size of the picture drawn into, in pixels.
  public func setFrameSize(width: Int, height: Int) {
    ass_set_frame_size(pointer, Int32(width), Int32(height))
  }

  /// Times the size the script's styles ask for; 1 as written.
  public func setFontScale(_ scale: Double) {
    ass_set_font_scale(pointer, scale)
  }

  /// The video's own resolution, used to keep aspect-dependent effects
  /// right when the picture is scaled.
  public func setStorageSize(width: Int, height: Int) {
    ass_set_storage_size(pointer, Int32(width), Int32(height))
  }

  public func render(_ track: ASSTrack, atMilliseconds time: Int64) -> ASSFrame {
    var change: Int32 = 0
    var images: [ASSImage] = []
    var node = ass_render_frame(pointer, track.pointer, time, &change)
    while let image = node {
      let piece = image.pointee
      if piece.w > 0, piece.h > 0, let bitmap = piece.bitmap {
        let stride = Int(piece.stride)
        let length = stride * (Int(piece.h) - 1) + Int(piece.w)
        images.append(ASSImage(
          x: Int(piece.dst_x), y: Int(piece.dst_y),
          width: Int(piece.w), height: Int(piece.h), stride: stride,
          coverage: Array(UnsafeBufferPointer(start: bitmap, count: length)),
          color: piece.color))
      }
      node = piece.next
    }
    return ASSFrame(images: images, isChanged: change != 0)
  }
}
