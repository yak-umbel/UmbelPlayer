import Foundation

extension Duration {
  /// The length in seconds, for comparing with media time.
  var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Sleeps, and says how long that really took, which on a busy machine is more
/// than was asked: a clock is to be compared with this, not with the request.
func sleepMeasured(_ seconds: Double) async throws -> Double {
  let started = ContinuousClock.now
  try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  return (ContinuousClock.now - started).inSeconds
}
