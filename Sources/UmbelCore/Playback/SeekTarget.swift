import CoreMedia

/// Where a seek lands.
internal enum SeekTarget {
  /// Clamped below at 0; above only when the duration is known. An unknown
  /// duration does not mean no seeking: that is `isSeekable`'s to say.
  static func clamped(_ time: CMTime, duration: CMTime) -> CMTime {
    var target = time
    if target < .zero { target = .zero }
    if duration.isValid, !duration.isIndefinite, target > duration { target = duration }
    return target
  }
}
