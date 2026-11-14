import CoreGraphics
import CoreMedia
import Foundation

/// The renderer's result for a presentation call, not confirmation that the
/// GPU completed its work or the display showed the picture: the picture was
/// decoded and handed to the renderer's output to be shown.
public struct PresentedFrame: Sendable, Equatable {
  public let presentationTime: CMTime
  /// Late queued frames discarded before this one. A late presentation
  /// call can cause drops even when decoding keeps up; this count alone
  /// cannot distinguish scheduling delays from insufficient decoded frames.
  public let droppedFrames: Int
  /// The session's `seekGeneration` this picture follows: the latest seek
  /// that had restarted playback at its target when the session presented
  /// it, 0 for a picture from before any seek. Set by the session; a
  /// renderer leaves it be.
  public internal(set) var seekGeneration = 0

  public init(presentationTime: CMTime, droppedFrames: Int) {
    self.presentationTime = presentationTime
    self.droppedFrames = droppedFrames
  }
}

/// Where video is drawn.
///
/// **A renderer owns no display loop**; it only answers which frame to draw
/// at time T. For two reasons: none of the system's display link interfaces
/// reaches this project's platform floor (`CADisplayLink` needs macOS 14,
/// `NSView.displayLink` 15, and `CVDisplayLink` is deprecated), so holding
/// one in the core would mean version branches and deprecated calls; and a
/// loop inside could not be stepped by hand in tests.
///
/// The same thinking as the clock's: time is asked, not pushed.
public protocol VideoRenderer: Sendable {
  /// What this renderer can currently do. Custom renderers default to unsupported.
  var videoCapabilities: UmbelVideoCapabilities { get async }
  /// Prepares for a size and colour. Calling it again reconfigures.
  ///
  /// The values describe the canvas before the first frame arrives.
  /// `width` and `height` are stored pixels; `pixelAspectRatio` is the width
  /// of one over its height as shown, so the picture is shown
  /// `width × pixelAspectRatio` wide. A session preparing for a track turned
  /// a quarter (see `UmbelVideoRotation`) passes the turned shape instead:
  /// the shown width and height, at a pixel aspect ratio of 1. Frames carry
  /// their own size, shape and rotation and override these as they are drawn
  /// — a broadcast may switch between 4:3 and 16:9 — and a frame's `width`
  /// and `height` are always stored pixels; its `displaySize` is the shape
  /// to draw.
  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws
  /// Hands over a frame, waiting while the queue is full: backpressure.
  func enqueue(_ frame: VideoFrame) async throws
  /// Presents the frame due at `time`. Nil means nothing new to present,
  /// and the caller keeps showing the last one.
  func presentFrame(at time: CMTime) async throws -> PresentedFrame?
  /// Drops the frames waiting to be presented. Called after a seek.
  func flush() async
  var queueDepth: Int { get async }
  var totalDroppedFrames: Int { get async }

  /// The size subtitles are laid out for: the picture in pixels, as drawn.
  /// Zero until prepared.
  var subtitleCanvasSize: CGSize { get async }
  /// Subtitles to draw over the picture from now on, framed in
  /// `subtitleCanvasSize` pixels. Drawn by the next `presentFrame(at:)` —
  /// over the last frame again when no new one is due, since a line
  /// appearing while paused still has to show.
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async
  /// Where the whole picture is in the subtitle canvas's pixels: the
  /// canvas itself while the picture fits, reaching past it when the
  /// picture fills the output and is cut off. Bitmap subtitles, placed by
  /// the picture, go by it.
  var subtitlePictureFrame: CGRect { get async }
  /// Adjusts video RGB on the next presentation; custom renderers may ignore this.
  func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async
  /// Shows the picture at `aspectRatio` (width over height; nil, the
  /// source's own), scaled into the output by `scaling`. Subtitles are laid
  /// out on the part of the picture that shows. From the next picture drawn.
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async
}

extension VideoRenderer {
  public func setVideoAdjustments(_ adjustments: UmbelVideoAdjustments) async {}

  public var videoCapabilities: UmbelVideoCapabilities {
    get async {
      UmbelVideoCapabilities(canOverrideAspectRatio: false, canScalePicture: false,
                             snapshot: .unsupported(.rendererUnsupported))
    }
  }
  /// The picture is the canvas: how every renderer that does not cut the
  /// picture off lays subtitles out.
  public var subtitlePictureFrame: CGRect {
    get async { CGRect(origin: .zero, size: await subtitleCanvasSize) }
  }

  /// Square pixels.
  public func prepare(width: Int, height: Int, color: VideoColorDescription) async throws {
    try await prepare(width: width, height: height, pixelAspectRatio: 1, color: color)
  }

  /// Prepares for a track's size and pixel shape. The colour description is
  /// only known from the frames; until something passes it on, limited range
  /// is assumed.
  ///
  /// Before the first frame the canvas is the picture as it will be shown:
  /// for a quarter turn, the turned shape, so the view is not sized sideways
  /// for an instant. Frames measure themselves once they arrive. On the
  /// system's display path nothing is turned, and the stored size stands.
  func prepare(for track: UmbelTrack, plan: VideoPresentationPlan? = nil) async throws {
    let video = track.video
    if let plan { await (self as? any VideoRoutePreparing)?.setVideoPresentationPlan(plan) }
    else {
      await (self as? any VideoRoutePreparing)?.setSystemVideoRoute(
        video?.dynamicHDR?.requiresSystemDisplay ?? false)
    }
    let color: VideoColorDescription
    if let signal = video?.signal {
      let curve = signal.transferCode == 0 || signal.transferCode == 2
        ? (video?.transfer == .pq ? Int32(16) : video?.transfer == .hlg ? Int32(18) : Int32(2)) : signal.transferCode
      color = try .from(colorspace: signal.matrixCode, range: signal.rangeCode,
        transfer: curve, primaries: signal.primariesCode)
    } else {
      color = VideoColorDescription(matrix: .unspecified, range: .limited, transfer: video?.transfer ?? .sdr)
    }
    if let video, video.appliedRotation.swapsAxes {
      try await prepare(
        width: video.displayWidth, height: video.displayHeight, pixelAspectRatio: 1, color: color)
    } else {
      try await prepare(
        width: video?.width ?? 0, height: video?.height ?? 0,
        pixelAspectRatio: video?.pixelAspectRatio ?? 1, color: color)
    }
  }
}

/// The last visible picture in fractions of the renderer's view.
internal protocol PictureFrameReporting: Actor {
  var normalizedPictureFrame: CGRect? { get async }
}
