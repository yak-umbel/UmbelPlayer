import Foundation

/// HDR whose brightness is described frame by frame, on top of a video
/// track's own colour. Neutral names only: this is DV, by its profile.
public enum UmbelDynamicHDR: Sendable, Equatable {
  /// A DV track, by its configuration record: `compatibility` says what its
  /// base layer is on its own — 0 nothing, 1 HDR10, 2 SDR, 4 HLG, 6 the
  /// HDR10 of a disc.
  case dv(profile: Int, level: Int, compatibility: Int)

  /// No base layer of its own (profile 5): the pictures are in a colour
  /// space only DV's processing turns into light, which the system does.
  public var requiresSystemDisplay: Bool {
    switch self {
    case .dv(_, _, let compatibility): return compatibility == 0
    }
  }

  /// What the base layer is when it is complete on its own, and so is shown
  /// as it is. Nil when the system has to show the track, or when the
  /// compatibility is one this version does not know — the track's own
  /// colour tags decide then.
  public var baseLayer: UmbelDVBaseLayer? {
    switch self {
    case .dv(_, _, let compatibility):
      switch compatibility {
      case 1, 6: return .hdr10
      case 4: return .hlg
      case 2: return .sdr
      default: return nil
      }
    }
  }

  /// "DV P5", "DV P8.1", "DV P8.4", "DV P7": profile 8 is named with its
  /// base layer, the way it is usually spoken of.
  public var label: String {
    switch self {
    case .dv(let profile, _, let compatibility):
      if profile == 8, [1, 2, 4].contains(compatibility) { return "DV P8.\(compatibility)" }
      return "DV P\(profile)"
    }
  }
}

/// A DV base layer complete on its own.
public enum UmbelDVBaseLayer: Sendable, Equatable {
  case hdr10
  case hlg
  case sdr

  /// The transfer to take where the base layer declares none.
  public var transfer: UmbelTransferFunction {
    switch self {
    case .hdr10: return .pq
    case .hlg: return .hlg
    case .sdr: return .sdr
    }
  }
}
