extension PlaybackSession {
  /// The rates it plays at: from half the normal speed to twice it.
  public static let supportedRates: ClosedRange<Double> = 0.5...2.0

  /// Plays `rate` times the normal speed, keeping the pitch; a rate outside
  /// `supportedRates` is held to it, and one that is not a number is left
  /// out. While playing it takes effect at once, going on from where it
  /// is; set before loading, from the start. It stays through pauses, seeks
  /// and track switches.
  public func setRate(_ rate: Double) async {
    guard rate.isFinite else { return }
    self.rate = min(max(rate, Self.supportedRates.lowerBound), Self.supportedRates.upperBound)
    await pipeline?.setRate(self.rate)
  }
}
