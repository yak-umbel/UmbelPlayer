/// Video-only adjustments, applied before subtitle composition.
/// Finite inputs clamp to their ranges; non-finite inputs use neutral defaults.
public struct UmbelVideoAdjustments: Sendable, Equatable {
  /// Offset in output reference whites, clamped to -1...1. Neutral is zero.
  public let brightness: Double
  /// Multiplier around half output reference white, clamped to 0...2.
  public let contrast: Double
  /// Luminance-to-color multiplier in output primaries, clamped to 0...2.
  public let saturation: Double

  public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
    self.brightness = brightness.isFinite ? min(max(brightness, -1), 1) : 0
    self.contrast = contrast.isFinite ? min(max(contrast, 0), 2) : 1
    self.saturation = saturation.isFinite ? min(max(saturation, 0), 2) : 1
  }
}
