import AVFoundation
import CoreMedia
import Foundation

/// The system's sample buffer audio renderer, as the output uses it: a
/// protocol so the output can be checked without audio hardware.
internal protocol AudioSampleRendering: AnyObject, Sendable {
  /// What goes on the timeline.
  var queued: QueuedRenderer { get }
  var isReadyForMoreMediaData: Bool { get }
  var hasFailed: Bool { get }
  /// Why it failed, as the system says; nil while it has not.
  var failure: String? { get }
  var volume: Float { get set }
  var isMuted: Bool { get set }
  func enqueue(_ buffer: CMSampleBuffer)
  func flush()
}

/// The real one. It keeps the pitch at other rates, and says so through
/// `onDiscarded` — on any thread — whenever it dropped what it held on its
/// own: when playback moves to another output device, on some changes of
/// rate, and when the device's configuration no longer suits the sound.
internal final class SystemAudioRenderer: AudioSampleRendering, @unchecked Sendable {
  private let renderer = AVSampleBufferAudioRenderer()
  private var observers: [NSObjectProtocol] = []
  private let diagnosticLock = NSLock()
  private var diagnostics: UmbelPlaybackDiagnostics?

  func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) {
    diagnosticLock.withLock { self.diagnostics = diagnostics }
  }

  private func recordDiscard(_ notification: Notification) {
    guard let diagnostics = diagnosticLock.withLock({ diagnostics }) else { return }
    var values: [String: Double] = [
      "volume": Double(renderer.volume), "muted": renderer.isMuted ? 1 : 0,
      "status": Double(renderer.status.rawValue), "ready": renderer.isReadyForMoreMediaData ? 1 : 0,
      "sufficient": renderer.hasSufficientMediaDataForReliablePlaybackStart ? 1 : 0,
    ]
    if let time = notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue {
      values["flushPTS"] = time.timeValue.seconds
    }
    diagnostics.record("audio_renderer_discard", values: values, labels: [
      "reason": notification.name == .AVSampleBufferAudioRendererWasFlushedAutomatically
        ? "automaticFlush" : "outputConfigurationChanged",
    ])
  }

  init(volume: Float, onDiscarded: @escaping @Sendable () -> Void) {
    renderer.volume = volume
    // Set once, before it plays: changed while it runs, the timeline may
    // stop for a moment.
    renderer.audioTimePitchAlgorithm = .spectral
    // Multichannel sound is spatialized on headphones that can. Stereo and
    // mono are allowed too: on the iPad stereo then follows the listener's
    // head as multichannel does; on macOS the system offered stereo
    // spatialization to its own player only, not to this renderer.
    renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      .AVSampleBufferAudioRendererWasFlushedAutomatically,
      .AVSampleBufferAudioRendererOutputConfigurationDidChange,
    ]
    for name in names {
      observers.append(center.addObserver(forName: name, object: renderer, queue: nil) { [weak self] notice in
        self?.recordDiscard(notice)
        onDiscarded()
      })
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  var queued: QueuedRenderer { QueuedRenderer(renderer: renderer) }
  var isReadyForMoreMediaData: Bool { renderer.isReadyForMoreMediaData }
  var hasFailed: Bool { renderer.status == .failed }
  var failure: String? { hasFailed ? renderer.error.map { "\($0)" } ?? "no reason given" : nil }
  var volume: Float {
    get { renderer.volume }
    set { renderer.volume = newValue }
  }
  var isMuted: Bool {
    get { renderer.isMuted }
    set { renderer.isMuted = newValue }
  }
  func enqueue(_ buffer: CMSampleBuffer) { renderer.enqueue(buffer) }
  func flush() { renderer.flush() }
}
