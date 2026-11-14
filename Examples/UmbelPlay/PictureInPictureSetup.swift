import AVFoundation
import AppKit
import CoreMedia
import Metal
import UmbelCore
import UmbelUI

/// The system's display layer beside the window's picture: a second renderer
/// on it, a switch between it and the window's, and with `--pip` the
/// system's picture in picture controller over both.
///
/// It is made whatever the options: a picture only the system can show (DV
/// profile 5) goes to it. For that it lies below the window's picture, whose
/// renderer then draws the subtitles alone, see-through. Otherwise it lies
/// over it — the controller wants one in a window on screen — and, empty,
/// is clear: it shows only while picture in picture takes the picture.
@MainActor
final class PictureInPictureSetup {
  /// Held as `DisplayLayerHandle` holds the window's layer, and for the same
  /// reason: the renderer enqueues into it, the main thread only sets it up.
  private struct Handle: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
  }

  private let handle: Handle
  let renderer: SwitchingVideoRenderer
  var layer: AVSampleBufferDisplayLayer { handle.layer }
  private var controller: UmbelPictureInPicture?

  init?(main: MetalVideoRenderer) {
    let handle = Handle()
    guard let device = MTLCreateSystemDefaultDevice(),
          let second = try? SampleBufferVideoRenderer(
            layer: handle.layer, device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    else { return nil }
    self.handle = handle
    renderer = SwitchingVideoRenderer(main: main, pictureInPicture: second)
  }

  /// Once the window is up. The layer is hosted by a view of its own, which
  /// keeps it the window's size; while picture in picture is open the
  /// controller gives it the small window's size instead.
  func attach(
    to view: NSView, picture: NSView, below: Bool, session: PlaybackSession, controls: Bool
  ) {
    layer.videoGravity = .resizeAspect
    // A layer the view hosts rather than backs is not given the screen's
    // scale. On macOS the small window mirrors it pixel for pixel, so the
    // scale decides how big it shows there.
    layer.contentsScale = view.window?.backingScaleFactor ?? 2
    let host = NSView(frame: view.bounds)
    host.layer = layer
    host.wantsLayer = true
    host.autoresizingMask = [.width, .height]
    view.addSubview(host, positioned: below ? .below : .above, relativeTo: picture)
    // Below, it is what shows around the picture — the overlay above is
    // see-through there: black bars, as the window's own renderer draws.
    // Above, it stays clear, or it would cover the picture.
    if below { layer.backgroundColor = CGColor(gray: 0, alpha: 1) }
    guard controls else { return }
    controller = UmbelPictureInPicture(layer: layer, session: session, renderer: renderer)
    if controller == nil { print("picture in picture: not available here") }
  }

  func toggle() {
    guard let controller else { return }
    if controller.isActive {
      controller.stop()
      print("command: picture in picture off")
    } else {
      controller.start()
      print("command: picture in picture on")
    }
    fflush(stdout)
  }
}
