import CoreMedia

/// Which field of an interlaced frame comes first in time: the top one (the
/// even rows, from 0) or the bottom one (the odd rows).
internal enum FieldOrder: Sendable, Equatable {
  case topFirst
  case bottomFirst
}

/// How far apart an interlaced frame's two fields are shown.
internal enum FieldTiming {
  /// Half the frame's duration, unless the frame rate the stream declares
  /// shows the duration to be one field's: a frame made of two field pictures
  /// takes its duration from the first field's packet, and the fields are
  /// then a whole such duration apart. A declared rate that agrees with
  /// neither reading is not believed — some encoders write a field rate where
  /// a frame rate belongs, or the other way round.
  ///
  /// With no duration: from the declared frame rate, then the track's nominal
  /// one — each only if a frame can have it: some streams write the system
  /// clock, 27 MHz, where a frame rate belongs, and half of its period is no
  /// time at all. Nil when none is known — the deinterlacer then goes by how the
  /// frames are spaced (`FramePeriodEstimator`), and failing that, shows only
  /// the first field.
  static func step(duration: CMTime, declaredFrameRate: Double? = nil, nominalFrameRate: Double?) -> CMTime? {
    if duration.isNumeric, duration.seconds > 0 {
      if let rate = declaredFrameRate, rate.isFinite, rate > 0,
         abs(0.5 / rate - duration.seconds) <= 0.1 * duration.seconds {
        return duration
      }
      return CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
    }
    for rate in [declaredFrameRate, nominalFrameRate] {
      if let rate, rate.isFinite, rate > 0, FramePeriodEstimator.plausible.contains(1 / rate) {
        return CMTime(seconds: 0.5 / rate, preferredTimescale: 90_000)
      }
    }
    return nil
  }
}
