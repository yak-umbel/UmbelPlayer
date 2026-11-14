import Foundation
import simd

/// Colour parameters for the shader, in the order of its struct.
///
/// Samples arrive normalised by their texture: an 8-bit code over 255, a
/// 10-bit one in P010 as code × 64 over 65535. Offsets and scales undo that
/// exactly for each depth; treating 10-bit as 8-bit would put white a few
/// codes off, which shows as a brightness error once the picture is HDR.
internal struct ColorUniforms {
  internal var lumaOffset: Float
  internal var lumaScale: Float
  internal var chromaOffset: Float
  internal var chromaScale: Float
  /// Each output channel is luma plus `x` × Cb plus `y` × Cr.
  internal var red: SIMD4<Float>
  internal var green: SIMD4<Float>
  internal var blue: SIMD4<Float>
  /// 0 none; 1 PQ and 2 HLG to standard range. See `setToneMapping(for:)`.
  internal var toneMap: Int32 = 0
  /// The film's peak in nits, and where it should land: SDR white, taken
  /// as BT.2408's HDR reference white.
  internal var sourcePeak: Float = 1000
  internal var targetPeak: Float = 203
  /// For an HDR target: 1 decodes PQ to linear light at 100 nits a unit,
  /// 2 decodes HLG to scene light 0...12, the scale the system's HLG
  /// metadata takes. 0 leaves the values as they are.
  internal var linearOutput: Int32 = 0
  internal var sourceTransfer: Int32 = 1
  internal var inputRGB: Int32 = 0
  internal var convertGamut: Int32 = 0
  internal var ditherOutput: Int32 = 0
  internal var chromaScaleUV = SIMD2<Float>(1, 1)
  internal var chromaOffsetUV = SIMD2<Float>(0, 0)
  internal var gamutRed = SIMD4<Float>(1, 0, 0, 0)
  internal var gamutGreen = SIMD4<Float>(0, 1, 0, 0)
  internal var gamutBlue = SIMD4<Float>(0, 0, 1, 0)
  /// Brightness, contrast, saturation, and output reference white.
  internal var adjustments = SIMD4<Float>(0, 1, 1, 1)
  internal var luminanceWeights = SIMD4<Float>(0.2126, 0.7152, 0.0722, 0)

  internal mutating func setAdjustments(_ value: UmbelVideoAdjustments, output: VideoOutput) {
    let white: Float = output.encoding == .pq ? 2.03 : output.encoding == .hlg ? 3.1796 : 1
    adjustments = SIMD4(Float(value.brightness), Float(value.contrast), Float(value.saturation), white)
    luminanceWeights = output.isStandard && output.encoding != .standardLinear2020
      ? SIMD4(0.2126, 0.7152, 0.0722, 0) : SIMD4(0.2627, 0.6780, 0.0593, 0)
  }

  internal mutating func setGamut(for color: VideoColorDescription, output: VideoOutput) {
    let to2020 = !output.isStandard || color.isHDR || output.encoding == .standardLinear2020
    let matrix = ColorGamutTransform.matrix(for: color, to2020: to2020)
    if simd_length(matrix.columns.0 - SIMD3<Float>(1, 0, 0)) < 0.00001,
       simd_length(matrix.columns.1 - SIMD3<Float>(0, 1, 0)) < 0.00001,
       simd_length(matrix.columns.2 - SIMD3<Float>(0, 0, 1)) < 0.00001 { return }
    convertGamut = 1
    gamutRed = SIMD4(matrix[0, 0], matrix[1, 0], matrix[2, 0], 0)
    gamutGreen = SIMD4(matrix[0, 1], matrix[1, 1], matrix[2, 1], 0)
    gamutBlue = SIMD4(matrix[0, 2], matrix[1, 2], matrix[2, 2], 0)
  }

  /// `matrix` is the one to draw with, already resolved from an undeclared
  /// one; see `VideoColorDescription.matrix(forWidth:height:)`.
  internal init(for color: VideoColorDescription, matrix: UmbelColorMatrix, isTenBit: Bool) {
    self.init(for: color, matrix: matrix, bitDepth: isTenBit ? 10 : 8)
  }

  internal init(for color: VideoColorDescription, matrix: UmbelColorMatrix, bitDepth: Int) {
    // One code step, in the texture's normalised units.
    let isTenBit = bitDepth == 10
    let unit: Float = bitDepth > 8 ? pow(2, Float(16 - bitDepth)) / 65535 : 1 / 255
    let (black, lumaRange, chromaRange): (Float, Float, Float) = {
      switch (color.range, isTenBit) {
      case (.limited, false): return (16, 219, 224)
      case (.limited, true): return (64, 876, 896)
      case (.full, false): return (0, 255, 255)
      case (.full, true): return (0, 1023, 1023)
      }
    }()
    let factor = pow(2, Float(bitDepth - 8))
    let maxCode = pow(2, Float(bitDepth)) - 1
    lumaOffset = (bitDepth > 10 ? (color.range == .full ? 0 : 16 * factor) : black) * unit
    lumaScale = 1 / ((bitDepth > 10 ? (color.range == .full ? maxCode : 219 * factor) : lumaRange) * unit)
    chromaOffset = pow(2, Float(bitDepth - 1)) * unit
    chromaScale = 1 / ((bitDepth > 10 ? (color.range == .full ? maxCode : 224 * factor) : chromaRange) * unit)

    // From the luma weights of red and blue, as every Y′CbCr matrix is built.
    let (kr, kb): (Float, Float) = {
      switch matrix {
      case .bt601: return (0.299, 0.114)
      case .bt2020: return (0.2627, 0.0593)
      case .bt709, .unspecified: return (0.2126, 0.0722)
      }
    }()
    let kg = 1 - kr - kb
    red = SIMD4(0, 2 * (1 - kr), 0, 0)
    green = SIMD4(-2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 0, 0)
    blue = SIMD4(2 * (1 - kb), 0, 0, 0)
  }

  /// Sets the uniforms up to tone-map `color` to standard range. The peak is
  /// the film's own where it says: MaxCLL, else the mastering display's
  /// maximum, else 1000 nits — the common grade. HLG is taken as shown on a
  /// 1000-nit display, the reference its OOTF is defined for.
  internal mutating func setToneMapping(for color: VideoColorDescription) {
    switch color.transfer {
    case .sdr:
      toneMap = 0
      return
    case .pq:
      toneMap = 1
      let declared = [
        color.hdr?.maxContentLightLevel.map(Double.init),
        color.hdr?.masteringDisplay?.maxLuminance,
      ].compactMap { $0 }.first { $0 > 0 }
      sourcePeak = Float(declared ?? 1000)
    case .hlg:
      toneMap = 2
      sourcePeak = 1000
    }
  }
}
