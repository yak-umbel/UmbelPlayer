import AVFoundation
import CoreMedia
import UmbelObjCSupport

/// Where a sample buffer renderer's pictures go: the system's sample buffer
/// display layer — picture in picture takes its content from one — or a
/// test's record. Called from any thread.
internal protocol SampleBufferSink: Sendable {
  func enqueue(_ buffer: CMSampleBuffer)
  /// Drops what is queued and what shows, and clears a failure.
  func flush()
  /// The system gave up on it — after its window went off screen, say; it
  /// shows nothing more until flushed.
  var hasFailed: Bool { get }
  /// Whether it takes more now; a full one holds the next sample back.
  var isReadyForMoreMediaData: Bool { get }
  /// Puts the layer on `timeline` in place of its own timebase `own` — the
  /// system will not take a layer that has one — and back on `own` if the
  /// system refuses it.
  func join(_ timeline: any SystemTimeline, replacing own: CMTimebase) async throws
  /// Off `timeline`, back on `own`.
  func leave(_ timeline: any SystemTimeline, restoring own: CMTimebase) async
  /// Whether the picture covers the view, its edges cut off, or fits in it.
  func setFillsView(_ fills: Bool)
}

extension SampleBufferSink {
  func join(_ timeline: any SystemTimeline, replacing own: CMTimebase) async throws {}
  func leave(_ timeline: any SystemTimeline, restoring own: CMTimebase) async {}
  func setFillsView(_ fills: Bool) {}
}

/// Accepts pictures from any thread, timed by the layer's control timebase.
/// Layer access stays on the main actor; newer systems enqueue directly to
/// the separate renderer, which supports background submission.
internal final class DisplayLayerSink: SampleBufferSink, @unchecked Sendable {
  private let layer: AVSampleBufferDisplayLayer
  private let output: any SampleBufferSink

  init(layer: AVSampleBufferDisplayLayer) {
    self.layer = layer
    self.output = DisplayLayerAccess(layer: layer).sync { layer in
      if #available(macOS 14, iOS 17, tvOS 17, *) {
        return VideoRendererSink(renderer: layer.sampleBufferRenderer)
      }
      return LegacyDisplayLayerSink(layer: layer)
    }
  }

  func enqueue(_ buffer: CMSampleBuffer) { output.enqueue(buffer) }

  /// The picture showing goes too: after a seek it no longer belongs, and
  /// a layer over another picture would cover it with a stale one.
  func flush() { output.flush() }

  var hasFailed: Bool { output.hasFailed }

  var isReadyForMoreMediaData: Bool { output.isReadyForMoreMediaData }

  /// The system raises for a layer already on a timeline — a host that gave
  /// it to two renderers — even to clear its timebase: refused, it stays
  /// where it is.
  func join(_ timeline: any SystemTimeline, replacing own: CMTimebase) async throws {
    try await MainActor.run {
      let layer = self.layer
      var failure: NSError?
      guard UmbelCatchingObjCException({ layer.controlTimebase = nil }, &failure) else {
        throw failure ?? NSError(domain: "UmbelDisplayLayer", code: 1)
      }
      do {
        try timeline.add(QueuedRenderer(renderer: layer))
      } catch {
        _ = UmbelCatchingObjCException({ layer.controlTimebase = own }, nil)
        throw error
      }
    }
  }

  /// On the main thread, where layers are set up.
  func setFillsView(_ fills: Bool) {
    let layer = self.layer
    Task { @MainActor in layer.videoGravity = fills ? .resizeAspectFill : .resizeAspect }
  }

  func leave(_ timeline: any SystemTimeline, restoring own: CMTimebase) async {
    await timeline.remove(QueuedRenderer(renderer: layer))
    await MainActor.run {
      let layer = self.layer
      _ = UmbelCatchingObjCException({ layer.controlTimebase = own }, nil)
    }
  }
}

/// The renderer is acquired on the main actor once. Its queue interfaces
/// support background calls without touching the display layer again.
@available(macOS 14, iOS 17, tvOS 17, *)
private final class VideoRendererSink: SampleBufferSink, @unchecked Sendable {
  private let renderer: AVSampleBufferVideoRenderer

  init(renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }

  func enqueue(_ buffer: CMSampleBuffer) { renderer.enqueue(buffer) }
  func flush() { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
  var hasFailed: Bool { renderer.status == .failed }
  var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
}

/// The compatibility queue for systems without a separate renderer. Calls
/// finish on the main actor before returning: a submission must not escape
/// the epoch lock and arrive after a seek has flushed it.
internal final class LegacyDisplayLayerSink: SampleBufferSink, @unchecked Sendable {
  private let layer: AVSampleBufferDisplayLayer

  init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

  func enqueue(_ buffer: CMSampleBuffer) {
    let sample = BorrowedSample(buffer: buffer)
    DisplayLayerAccess.sync { layer.enqueue(sample.buffer) }
  }

  func flush() { DisplayLayerAccess.sync { layer.flushAndRemoveImage() } }
  var hasFailed: Bool { DisplayLayerAccess.sync { layer.status == .failed } }
  var isReadyForMoreMediaData: Bool { DisplayLayerAccess.sync { layer.isReadyForMoreMediaData } }

  /// The caller lends a completed sample for a synchronous, read-only call.
  /// It cannot resume until enqueue returns; this box never defers that call
  /// or makes the sample globally Sendable. As with direct enqueue, callers
  /// must not mutate a sample's contents while the system renders it.
  private struct BorrowedSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
  }
}
