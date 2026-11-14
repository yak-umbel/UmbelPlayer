import Foundation
import Metal
import QuartzCore

/// Whether HDR is shown as HDR.
public enum UmbelDynamicRange: Sendable, Equatable {
  /// As HDR wherever the system can show it: macOS 13 and iOS 16 on, on any
  /// display, the system tone-mapping to what that display can do. Elsewhere
  /// tone-mapped to standard range.
  case automatic
  /// Always tone-mapped to standard range: to save power, for a display
  /// mirrored to an SDR set, or because the viewer prefers it.
  case standard
}

/// What a renderer's target holds.
///
/// Precision and dynamic range are independent. High precision SDR and
/// HDR use linear light in half floats — PQ at 100 nits
/// a unit, HLG as scene light 0...12 — in extended linear BT.2020, for the
/// system to show in extended dynamic range and tone-map to the display at
/// hand.
/// Linear, so that subtitles blend over them as light does, the way the
/// system composites its own layers. Where the system cannot show HDR, it
/// is tone-mapped to standard range before it is drawn.
internal struct VideoOutput: Equatable, Sendable {
  enum Encoding: Sendable { case standard, standardSRGB, standardLinear, standardLinear2020, pq, hlg }
  let encoding: Encoding
  let pixelFormat: MTLPixelFormat
  static let standard = Self(encoding: .standard, pixelFormat: .bgra8Unorm)
  static let standardSRGB = Self(encoding: .standardSRGB, pixelFormat: .bgra8Unorm)
  static let standardLinear = Self(encoding: .standardLinear, pixelFormat: .rgba16Float)
  static let standardLinear2020 = Self(encoding: .standardLinear2020, pixelFormat: .rgba16Float)
  static let pq = Self(encoding: .pq, pixelFormat: .rgba16Float)
  static let hlg = Self(encoding: .hlg, pixelFormat: .rgba16Float)

  func withFormat(_ format: MTLPixelFormat) -> Self { .init(encoding: encoding, pixelFormat: format) }

  static func choose(
    for transfer: UmbelTransferFunction, systemShowsHDR: Bool,
    bitDepth: Int? = 8, primaries: UmbelColorPrimaries = .bt709, permitsFloat32: Bool = false
  ) -> VideoOutput {
    let standard: VideoOutput = bitDepth == nil || (bitDepth ?? 0) > 8 || transfer != .sdr || primaries == .bt2020
      ? (transfer == .sdr && primaries == .bt2020 ? .standardLinear2020 : .standardLinear) : .standard
    let chosen: VideoOutput = !systemShowsHDR || transfer == .sdr ? standard : transfer == .pq ? .pq : .hlg
    return permitsFloat32 && (bitDepth ?? 0) > 10 ? chosen.withFormat(.rgba32Float) : chosen
  }

  var isStandard: Bool { encoding != .pq && encoding != .hlg }
  var isLinearStandard: Bool { encoding == .standardLinear || encoding == .standardLinear2020 }

  /// Shader encodings: sRGB, PQ, HLG, linear SDR, wide linear SDR, BT.709.
  var shaderCode: Int32 {
    switch encoding {
    case .standardSRGB: return 0
    case .standard: return 5
    case .standardLinear: return 3
    case .standardLinear2020: return 4
    case .pq: return 1
    case .hlg: return 2
    }
  }

  /// Whether the system can show HDR here, tone-mapping it to the display
  /// with the metadata given. Not on tvOS, before iOS 16 or before macOS 13,
  /// where it cannot say.
  static var systemShowsHDR: Bool {
    #if os(macOS)
    if #available(macOS 13, *) { return CAEDRMetadata.isAvailable }
    return false
    #elseif os(iOS)
    if #available(iOS 16, *) { return CAEDRMetadata.isAvailable }
    return false
    #else
    return false
    #endif
  }
}

/// HDR10's static metadata packed as the SEI messages carry it, the form
/// `CAEDRMetadata` takes: ITU-T H.265 D.2.28 and D.2.35, big-endian.
internal enum HDR10SEI {
  /// Primaries green, blue, red, then the white point, x and y in steps of
  /// 0.00002; then the maximum and minimum luminance in steps of 0.0001 nits.
  static func masteringDisplay(_ metadata: UmbelHDRMetadata) -> Data? {
    guard let display = metadata.masteringDisplay else { return nil }
    var bytes = Data()
    for point in [display.green, display.blue, display.red, display.whitePoint] {
      append(UInt16(clamping: Int((point.x / 0.00002).rounded())), to: &bytes)
      append(UInt16(clamping: Int((point.y / 0.00002).rounded())), to: &bytes)
    }
    append(UInt32(clamping: Int((display.maxLuminance / 0.0001).rounded())), to: &bytes)
    append(UInt32(clamping: Int((display.minLuminance / 0.0001).rounded())), to: &bytes)
    return bytes
  }

  static func contentLightLevel(_ metadata: UmbelHDRMetadata) -> Data? {
    guard let maxContent = metadata.maxContentLightLevel,
          let maxAverage = metadata.maxFrameAverageLightLevel else { return nil }
    var bytes = Data()
    append(UInt16(clamping: maxContent), to: &bytes)
    append(UInt16(clamping: maxAverage), to: &bytes)
    return bytes
  }

  private static func append<Value: FixedWidthInteger>(_ value: Value, to bytes: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
  }
}

/// How the display layer is set for one kind of picture.
internal struct DisplayLayerSetup: Equatable, Sendable {
  let output: VideoOutput
  let masteringDisplay: Data?
  let contentLight: Data?

  init(output: VideoOutput, metadata: UmbelHDRMetadata?) {
    self.output = output
    masteringDisplay = metadata.flatMap(HDR10SEI.masteringDisplay)
    contentLight = metadata.flatMap(HDR10SEI.contentLightLevel)
  }

  /// On the main thread, where macOS takes these settings reliably; set
  /// elsewhere, HDR has been seen not to take effect.
  @MainActor
  func apply(to layer: CAMetalLayer) {
    layer.pixelFormat = output.pixelFormat
    switch output.encoding {
    case .standard: layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
    case .standardSRGB: layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    case .standardLinear: layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    case .standardLinear2020, .pq, .hlg:
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
    }
    #if os(macOS) || os(iOS)
    guard #available(iOS 16, macOS 10.15, *), VideoOutput.systemShowsHDR else { return }
    switch output.encoding {
    case .standard, .standardSRGB, .standardLinear, .standardLinear2020:
      layer.wantsExtendedDynamicRangeContent = false
      layer.edrMetadata = nil
    case .pq:
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
      layer.wantsExtendedDynamicRangeContent = true
      // One unit is 100 nits, as the shader writes it — Apple's own example
      // scale. Missing parts fall back to the system's defaults.
      layer.edrMetadata = CAEDRMetadata.hdr10(
        displayInfo: masteringDisplay, contentInfo: contentLight, opticalOutputScale: 100)
    case .hlg:
      // Scene light, the inverse OETF already applied, as HLG metadata over a
      // linear colour space requires; the system applies the OOTF. On the
      // scale 0...12, which is what it takes (measured against its own
      // playback), though its header does not say.
      layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
      layer.wantsExtendedDynamicRangeContent = true
      layer.edrMetadata = CAEDRMetadata.hlg
    }
    #endif
  }
}

/// The display layer, handed to the main thread. It is only ever touched
/// there for these settings, and by the renderer's drawing otherwise.
internal struct MainThreadLayer: @unchecked Sendable {
  let layer: CAMetalLayer
}
