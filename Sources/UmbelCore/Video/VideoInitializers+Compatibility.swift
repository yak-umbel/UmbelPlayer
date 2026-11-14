/// Keep the original initializer symbols as well as their source call sites.
extension VideoColorDescription {
  public init(matrix: UmbelColorMatrix, range: UmbelColorRange,
              transfer: UmbelTransferFunction = .sdr, primaries: UmbelColorPrimaries = .bt709,
              hdr: UmbelHDRMetadata? = nil) {
    self.init(matrix: matrix, range: range, transfer: transfer, primaries: primaries,
              hdr: hdr, transferCode: nil)
  }
}

extension UmbelTrack.VideoDescription {
  public init(width: Int, height: Int, nominalFrameRate: Double?, pixelAspectRatio: Double = 1,
              transfer: UmbelTransferFunction = .sdr, dynamicHDR: UmbelDynamicHDR? = nil,
              rotation: UmbelVideoRotation = .none) {
    self.init(width: width, height: height, nominalFrameRate: nominalFrameRate,
      pixelAspectRatio: pixelAspectRatio, transfer: transfer, dynamicHDR: dynamicHDR,
      rotation: rotation, signal: nil)
  }
}

extension UmbelVideoCapabilities {
  public init(canOverrideAspectRatio: Bool, canScalePicture: Bool,
              snapshot: UmbelSnapshotAvailability, canAdjustColors: Bool = false) {
    self.init(canOverrideAspectRatio: canOverrideAspectRatio, canScalePicture: canScalePicture,
      snapshot: snapshot, canAdjustColors: canAdjustColors, subtitles: .unavailable)
  }
}
