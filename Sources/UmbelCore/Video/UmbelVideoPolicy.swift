/// Preference for original dynamic display metadata. This is independent
/// of the requested output dynamic range and precision.
public enum UmbelDynamicMetadataPreference: String, Sendable, Equatable {
  /// The system's dynamic-metadata display mapping wherever the system can show it; the compatible
  /// base layer where it cannot, and when the system refuses the pictures.
  case automatic
  /// Always the compatible base layer, treated as static HDR.
  case compatibleBaseLayer
}

public struct UmbelVideoPolicy: Sendable, Equatable {
  public var dynamicRange: UmbelDynamicRange
  public var dynamicMetadata: UmbelDynamicMetadataPreference

  public init(
    dynamicRange: UmbelDynamicRange = .automatic,
    dynamicMetadata: UmbelDynamicMetadataPreference = .automatic
  ) {
    self.dynamicRange = dynamicRange
    self.dynamicMetadata = dynamicMetadata
  }
}
