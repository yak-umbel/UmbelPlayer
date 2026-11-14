import Foundation
import UmbelFFmpegSupport

/// The matrix from YUV to RGB.
public enum UmbelColorMatrix: String, Sendable, Equatable {
  /// Standard definition: both broadcast systems' matrices, which are the same.
  case bt601
  case bt709
  /// Non-constant luminance, as HDR10 and HLG use it.
  case bt2020
  /// Not declared. The renderer guesses from the size; see
  /// `VideoColorDescription.matrix(forWidth:height:)`.
  case unspecified
}

/// The range sample values take.
public enum UmbelColorRange: String, Sendable, Equatable {
  /// Luma 16–235, chroma 16–240. Nearly all film and television.
  case limited
  /// 0–255.
  case full
}

/// How sample values relate to light.
public enum UmbelTransferFunction: String, Sendable, Equatable {
  /// Standard dynamic range: BT.709, BT.601, BT.2020's own, sRGB alike.
  case sdr
  /// SMPTE ST 2084, "perceptual quantizer": HDR10, and the base layer of DV P8.1.
  case pq
  /// Hybrid log-gamma, ARIB STD-B67: broadcast HDR.
  case hlg

  /// From FFmpeg's transfer characteristic code: 16 is ST 2084, 18 STD-B67,
  /// and everything else a standard-range curve.
  internal init(ffmpegCode code: Int32) {
    switch code {
    case 16: self = .pq
    case 18: self = .hlg
    default: self = .sdr
    }
  }
}

/// The colours the red, green and blue samples stand for.
public enum UmbelColorPrimaries: String, Sendable, Equatable {
  /// BT.709, and BT.601's two sets, which differ from it too little to matter.
  case bt709
  case bt2020
}

/// HDR10's static metadata: what the film was graded on, and how bright it
/// gets. Either part may be missing.
public struct UmbelHDRMetadata: Sendable, Equatable {
  public struct Chromaticity: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  /// SMPTE ST 2086: the mastering display's colour volume.
  public struct MasteringDisplay: Sendable, Equatable {
    public var red: Chromaticity
    public var green: Chromaticity
    public var blue: Chromaticity
    public var whitePoint: Chromaticity
    /// In nits (cd/m²).
    public var minLuminance: Double
    public var maxLuminance: Double

    public init(
      red: Chromaticity, green: Chromaticity, blue: Chromaticity, whitePoint: Chromaticity,
      minLuminance: Double, maxLuminance: Double
    ) {
      self.red = red
      self.green = green
      self.blue = blue
      self.whitePoint = whitePoint
      self.minLuminance = minLuminance
      self.maxLuminance = maxLuminance
    }
  }

  public var masteringDisplay: MasteringDisplay?
  /// MaxCLL: the brightest pixel in the film, in nits.
  public var maxContentLightLevel: Int?
  /// MaxFALL: the brightest frame on average, in nits.
  public var maxFrameAverageLightLevel: Int?

  public init(
    masteringDisplay: MasteringDisplay? = nil,
    maxContentLightLevel: Int? = nil,
    maxFrameAverageLightLevel: Int? = nil
  ) {
    self.masteringDisplay = masteringDisplay
    self.maxContentLightLevel = maxContentLightLevel
    self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
  }
}

/// A video track's colour.
public struct VideoColorDescription: Sendable, Equatable {
  public let matrix: UmbelColorMatrix
  public let range: UmbelColorRange
  public let transfer: UmbelTransferFunction
  public let primaries: UmbelColorPrimaries
  /// Present for HDR10 that carries it; HLG has none.
  public let hdr: UmbelHDRMetadata?
  /// Original transfer code, preserved even when its dynamic range is SDR.
  public let transferCode: Int32
  public let primariesCode: Int32?
  public let matrixCode: Int32?
  public let rangeCode: Int32?

  public init(
    matrix: UmbelColorMatrix,
    range: UmbelColorRange,
    transfer: UmbelTransferFunction = .sdr,
    primaries: UmbelColorPrimaries = .bt709,
    hdr: UmbelHDRMetadata? = nil,
    transferCode: Int32?,
    primariesCode: Int32? = nil, matrixCode: Int32? = nil, rangeCode: Int32? = nil
  ) {
    self.matrix = matrix
    self.range = range
    self.transfer = transfer
    self.primaries = primaries
    self.hdr = hdr
    self.transferCode = transferCode ?? (transfer == .pq ? 16 : transfer == .hlg ? 18 : 1)
    self.primariesCode = primariesCode
    self.matrixCode = matrixCode
    self.rangeCode = rangeCode
  }

  public var isHDR: Bool { transfer != .sdr }
  internal var workingPrimaries: UmbelColorPrimaries {
    if let code = primariesCode, ![0, 1, 2].contains(code) { return .bt2020 }
    return primaries
  }

  /// The matrix to draw with. An undeclared one is guessed from the size:
  /// wider than 1279 or taller than 576 is high definition and BT.709,
  /// anything smaller BT.601.
  public func matrix(forWidth width: Int, height: Int) -> UmbelColorMatrix {
    guard matrix == .unspecified else { return matrix }
    return width >= 1280 || height > 576 ? .bt709 : .bt601
  }

  /// From the raw values the container or decoder declares.
  ///
  /// A matrix declared plainly but not supported by this version **throws
  /// rather than being drawn as 709 without a word**: that would draw a
  /// colour cast, far harder to trace than an error.
  ///
  /// The values are FFmpeg's colour enumerations as integers, since this
  /// layer does not know the enumeration types beneath.
  public static func from(
    colorspace: Int32,
    range: Int32,
    transfer: Int32 = 2,
    primaries: Int32 = 2,
    hdr: UmbelHDRMetadata? = nil
  ) throws -> VideoColorDescription {
    guard [0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 13, 14, 15, 16, 18].contains(transfer) else {
      throw UmbelError.unsupportedColorMatrix("transfer=\(transfer)")
    }
    guard [0, 1, 2, 4, 5, 6, 7, 8, 9, 11, 12, 22].contains(primaries) else {
      throw UmbelError.unsupportedColorMatrix("primaries=\(primaries)")
    }
    let matrix: UmbelColorMatrix
    switch colorspace {
    case 1:                // BT.709
      matrix = .bt709
    case 4, 5, 6:          // FCC, BT.470 BG, SMPTE 170M: BT.601 in all but name
      matrix = .bt601
    case 9:                // BT.2020 non-constant luminance
      matrix = .bt2020
    case 0, 2:             // RGB / not declared
      matrix = .unspecified
    default:
      throw UmbelError.unsupportedColorMatrix("colorspace=\(colorspace)")
    }

    let curve = UmbelTransferFunction(ffmpegCode: transfer)

    // An undeclared range is taken as limited: overwhelmingly what film and
    // television use.
    let resolved: UmbelColorRange = (range == 2) ? .full : .limited
    return VideoColorDescription(
      matrix: matrix, range: resolved, transfer: curve,
      primaries: primaries == 9 ? .bt2020 : .bt709,
      hdr: curve == .sdr ? nil : hdr, transferCode: transfer,
      primariesCode: primaries, matrixCode: colorspace, rangeCode: range)
  }
}

extension UmbelHDRMetadata {
  /// From FFmpeg's shape. The mastering display counts only when both its
  /// colours and its luminance are given.
  internal init(ffmpeg metadata: FFmpegHDRMetadata) {
    var display: MasteringDisplay?
    if let p = metadata.primaries, p.count == 8,
       let minimum = metadata.minLuminance, let maximum = metadata.maxLuminance {
      display = MasteringDisplay(
        red: .init(x: p[0], y: p[1]), green: .init(x: p[2], y: p[3]),
        blue: .init(x: p[4], y: p[5]), whitePoint: .init(x: p[6], y: p[7]),
        minLuminance: minimum, maxLuminance: maximum)
    }
    self.init(
      masteringDisplay: display,
      maxContentLightLevel: metadata.maxContentLightLevel,
      maxFrameAverageLightLevel: metadata.maxFrameAverageLightLevel)
  }
}
