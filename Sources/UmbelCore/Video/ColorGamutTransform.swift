import simd

/// Linear RGB conversion derived from chromaticity coordinates and white points.
internal enum ColorGamutTransform {
  private struct Primaries {
    let red: SIMD2<Float>, green: SIMD2<Float>, blue: SIMD2<Float>
    var white = SIMD2<Float>(0.3127, 0.3290)
  }

  static func matrix(for color: VideoColorDescription, to2020: Bool) -> simd_float3x3 {
    let code = color.primariesCode.flatMap { $0 == 0 || $0 == 2 ? nil : $0 }
      ?? (color.primaries == .bt2020 ? 9 : 1)
    let source = primaries(code)
    let target = primaries(to2020 ? 9 : 1)
    var adaptation = matrix_identity_float3x3
    if source.white != target.white {
      let cone = simd_float3x3(columns: (
        SIMD3(0.8951, -0.7502, 0.0389), SIMD3(0.2664, 1.7135, -0.0685), SIMD3(-0.1614, 0.0367, 1.0296)))
      let scale = (cone * xyz(target.white)) / (cone * xyz(source.white))
      adaptation = cone.inverse * simd_float3x3(diagonal: scale) * cone
    }
    return rgbToXYZ(target).inverse * adaptation * rgbToXYZ(source)
  }

  private static func xyz(_ point: SIMD2<Float>) -> SIMD3<Float> {
    SIMD3(point.x / point.y, 1, (1 - point.x - point.y) / point.y)
  }

  private static func rgbToXYZ(_ p: Primaries) -> simd_float3x3 {
    let basis = simd_float3x3(columns: (xyz(p.red), xyz(p.green), xyz(p.blue)))
    let scale = basis.inverse * xyz(p.white)
    return simd_float3x3(columns: (basis.columns.0 * scale.x, basis.columns.1 * scale.y, basis.columns.2 * scale.z))
  }

  private static func primaries(_ code: Int32) -> Primaries {
    switch code {
    case 4: return .init(red: SIMD2(0.67, 0.33), green: SIMD2(0.21, 0.71), blue: SIMD2(0.14, 0.08), white: SIMD2(0.310, 0.316))
    case 5: return .init(red: SIMD2(0.64, 0.33), green: SIMD2(0.29, 0.60), blue: SIMD2(0.15, 0.06))
    case 6, 7: return .init(red: SIMD2(0.63, 0.34), green: SIMD2(0.31, 0.595), blue: SIMD2(0.155, 0.07))
    case 8: return .init(red: SIMD2(0.681, 0.319), green: SIMD2(0.243, 0.692), blue: SIMD2(0.145, 0.049), white: SIMD2(0.310, 0.316))
    case 9: return .init(red: SIMD2(0.708, 0.292), green: SIMD2(0.170, 0.797), blue: SIMD2(0.131, 0.046))
    case 11: return .init(red: SIMD2(0.68, 0.32), green: SIMD2(0.265, 0.69), blue: SIMD2(0.15, 0.06), white: SIMD2(0.314, 0.351))
    case 12: return .init(red: SIMD2(0.68, 0.32), green: SIMD2(0.265, 0.69), blue: SIMD2(0.15, 0.06))
    case 22: return .init(red: SIMD2(0.630, 0.340), green: SIMD2(0.295, 0.605), blue: SIMD2(0.155, 0.077))
    default: return .init(red: SIMD2(0.64, 0.33), green: SIMD2(0.30, 0.60), blue: SIMD2(0.15, 0.06))
    }
  }
}
