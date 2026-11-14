import CoreMedia
import Foundation

/// Where sound goes.
///
/// A protocol because **the clock's correctness can be checked no other
/// way**: a real output needs audio hardware, CI has none, and drift that
/// accumulates cannot be heard in ten seconds. The test double here is not
/// a stopgap but the only means of checking.
///
/// Two so far: the system's audio engine, and its sample buffer renderer
/// (`SampleBufferAudioOutput`), whose timeline the session's clock reads.
public protocol AudioOutput: Sendable {
  /// Prepares for the given format. Calling it again reconfigures.
  func prepare(sampleRate: Double, channelCount: Int) async throws
  /// Queues a frame, waiting while the queue is full: the backpressure.
  func enqueue(_ frame: AudioFrame) async throws
  /// Drops what is queued but not yet played, and the anchor, **without
  /// closing the device**.
  ///
  /// That is what a seek wants. `stop()` in its place would close the audio
  /// engine too, and starting the device again takes about half a second —
  /// half a second of a still picture and no sound, and dragging the progress
  /// bar stops following the finger.
  func flush() async
  func start() async throws
  func pause() async
  func stop() async
  /// Plays at `rate` times the normal speed — 0.5 half as fast, 2 twice —
  /// keeping the pitch. Every output has to: sound played at another speed
  /// than the clock runs would part from it.
  func setRate(_ rate: Double) async
  /// How loud it plays, 0 silent to 1 as recorded, and whether muted.
  /// Kept for what plays next: set before `prepare`, it holds from the
  /// first frame, and through tracks and a replaced device.
  func setVolume(_ volume: Float, muted: Bool) async
  /// The position played and the host time it was played at; nil before
  /// anything has played.
  var currentAnchor: RenderAnchor? { get async }
}

extension AudioOutput {
  /// Prepares for a track's format. A track that does not say gets the
  /// commonest one, 48 kHz stereo.
  func prepare(for track: UmbelTrack) async throws {
    let format = AudioOutputFormat.for(track)
    try await prepare(sampleRate: format.sampleRate, channelCount: format.channelCount)
  }
}
