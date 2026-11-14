/// Which seek the pictures presented follow, and the first one since the
/// latest seek: how a host tells that the picture of a seek is up.
///
/// A picture is told by the seek it follows, not by time passing, so it can be
/// told while paused, when the clock stands still. The state is changed in
/// step with the session's seek generation, with no suspension between, so
/// that a picture shown from before a seek cannot pass for one after it.
internal struct PictureSignal: Sendable {
  /// The latest seek playback has restarted at the target of (0: none yet).
  /// Pictures presented from then on follow it; before then they are still
  /// from where playback was.
  private(set) var settled = 0
  /// The first picture presented since the session started or the latest
  /// seek began.
  private(set) var first: PresentedFrame?

  /// A seek begins: its picture is yet to come.
  mutating func seekBegan() {
    first = nil
  }

  /// Playback has restarted at the target of the seek `generation`. A seek
  /// another has overtaken settles nothing.
  mutating func seekSettled(_ generation: Int, latest: Int) {
    if generation == latest { settled = generation }
  }

  /// Marks `frame`, which the renderer presented in answer to a call made
  /// when `settled` was `askedAt`: from before that, when a seek settled
  /// meanwhile. The first since the seek began is kept, if no seek has begun
  /// since the call was made.
  mutating func presented(_ frame: PresentedFrame, askedAt: Int, latest: Int) -> PresentedFrame {
    var marked = frame
    marked.seekGeneration = askedAt
    if first == nil, askedAt == settled, settled == latest { first = marked }
    return marked
  }
}
