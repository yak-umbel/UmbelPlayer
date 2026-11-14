import CoreMedia

/// Works out a stream's frame period from when its frames are shown, for
/// streams that state none: the spacing of consecutive frames, taken once
/// two in a row agree. Spacings that fit no frame rate of an interlaced
/// stream, or go back in time, are not taken and break the run.
///
/// The period belongs to the stream, so it stays through a seek; only the
/// position — the time of the frame before, the spacing before it — is
/// forgotten (`forgetPosition()`), as those no longer lead to the next frame.
internal struct FramePeriodEstimator {
  /// Spacings of 10 to about 60 frames a second; others are no frame period.
  static let plausible: ClosedRange<Double> = 0.016...0.1
  /// Two spacings agree when they differ by no more than this share of the
  /// larger — room for a millisecond time base's 33, 33, 34 ms.
  static let agreement = 0.05
  private static let timescale = 90_000.0

  /// The period the frames show; nil until two spacings agree.
  private(set) var period: CMTime?
  private var lastTime: Double?
  private var lastSpacing: Double?

  /// A frame's time to be shown at, in the order they come.
  mutating func observe(_ time: CMTime) {
    guard time.isNumeric else {
      forgetPosition()
      return
    }
    let now = time.seconds
    guard let before = lastTime else {
      lastTime = now
      return
    }
    lastTime = now
    let spacing = now - before
    guard Self.plausible.contains(spacing) else {
      lastSpacing = nil
      return
    }
    if let earlier = lastSpacing, abs(spacing - earlier) <= Self.agreement * max(spacing, earlier) {
      // Rounded to a tick: CMTime(seconds:) cuts 0.04 s down to 3599.
      let ticks = ((spacing + earlier) / 2 * Self.timescale).rounded()
      period = CMTime(value: Int64(ticks), timescale: Int32(Self.timescale))
    }
    lastSpacing = spacing
  }

  /// After a seek: what came before the next frame is not what comes before
  /// it now. The period stays.
  mutating func forgetPosition() {
    lastTime = nil
    lastSpacing = nil
  }
}
