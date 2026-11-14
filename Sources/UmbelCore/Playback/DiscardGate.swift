import CoreMedia
import Foundation

/// After a seek, frames earlier than the target have to go; this is that gate.
///
/// **Audio and video each keep their own threshold.** The two chains cross the
/// target at different moments, and with one shared field whichever crosses
/// first would clear it for the other, letting the other chain's early frames
/// through — heard and seen as the two drifting apart for a moment after a
/// seek. One rule, two pieces of state, which is why this is a type with two
/// fields rather than two optionals scattered across the session.
internal struct DiscardGate {
  private var audioThreshold: CMTime?
  private var videoThreshold: CMTime?
  /// The latest decoded picture held back before the target, in case the
  /// content ends before reaching it; see `videoFramesAtEnd(_:)`.
  private var lastHeldPicture: VideoFrame?

  /// Seeking: both chains have to catch up to the target.
  internal mutating func armBoth(at time: CMTime) {
    audioThreshold = time
    videoThreshold = time
    lastHeldPicture = nil
  }

  /// Only the audio chain needs realigning.
  internal mutating func armAudio(at time: CMTime) {
    audioThreshold = time
  }

  internal mutating func audioFramesToDeliver(_ frames: [AudioFrame]) -> [AudioFrame] {
    guard let threshold = audioThreshold else { return frames }
    let kept = frames.filter { Self.isDeliverable($0.presentationTime, threshold) }
    if !kept.isEmpty { audioThreshold = nil }
    return kept
  }

  internal mutating func videoFramesToDeliver(_ frames: [VideoFrame]) -> [VideoFrame] {
    guard let threshold = videoThreshold else { return frames }
    // A compressed frame goes on even before the target: the system decodes
    // the frames after from it, and it is marked not to be shown.
    let kept = frames.filter {
      $0.compressedSample != nil || Self.isDeliverable($0.presentationTime, threshold)
    }
    // Decoded frames come in presentation order: past the target, none
    // earlier follow, and the gate opens. Compressed ones come in decode
    // order — a frame before the target can follow one after it — so the
    // threshold stays until the next seek, each frame told by its own time.
    if kept.contains(where: {
      $0.compressedSample == nil && Self.isDeliverable($0.presentationTime, threshold)
    }) {
      videoThreshold = nil
      lastHeldPicture = nil
    } else if let held = frames.last(where: { $0.compressedSample == nil }) {
      lastHeldPicture = held
    }
    return kept
  }

  /// The video chain's last frames, when its content has run out. Content
  /// that ends before a seek's target — a seek to the very end, where a
  /// scrubber is let go — never opens the gate: then the last picture before
  /// the target goes on, so the end shows it rather than whatever was on
  /// screen before the seek.
  internal mutating func videoFramesAtEnd(_ frames: [VideoFrame]) -> [VideoFrame] {
    let kept = videoFramesToDeliver(frames)
    guard videoThreshold != nil, let held = lastHeldPicture else { return kept }
    videoThreshold = nil
    lastHeldPicture = nil
    return kept + [held]
  }

  /// Whether a video frame at `time` will be let through: before a seek's
  /// target it will not, so decoding it is worth only what later frames
  /// take from it. See `VideoDecodeSession.decode(_:hidden:)`.
  internal func hidesVideo(at time: CMTime) -> Bool {
    guard let threshold = videoThreshold else { return false }
    return !Self.isDeliverable(time, threshold)
  }

  /// Frames without a timestamp always pass. Dropping them would black out a
  /// source that omits timestamps after every seek, which is far worse than
  /// showing one frame too many.
  private static func isDeliverable(_ time: CMTime, _ threshold: CMTime) -> Bool {
    guard time.isValid else { return true }
    return time >= threshold
  }
}
