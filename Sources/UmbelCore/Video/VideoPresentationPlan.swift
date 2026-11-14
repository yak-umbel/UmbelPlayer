public enum UmbelVideoPresentationRoute: String, Sendable, Equatable, Codable {
  case metalPixels
  case systemPixels
  case systemCompressed

  internal var isSystem: Bool { self != .metalPixels }
}

/// Observations about transport. Submission is not proof of display mapping.
public enum UmbelDynamicMetadataStatus: String, Sendable, Equatable, Codable {
  case notPresent
  case declared
  case observed
  case submittedToSystem
  case baseLayerFallback
  case invalidatedByProcessing
  case unknown
}

internal struct VideoPresentationPlan: Sendable, Equatable {
  let route: UmbelVideoPresentationRoute
  let output: VideoOutput
  let metadata: UmbelDynamicMetadataStatus
  let reason: String?
}

internal struct VideoEnvironmentCapabilities: Sendable {
  var showsHDR = false
  var supportsHighPrecision = true
  var supportsP84SystemPixels = false
  var supportsSystemCompressed = false
  // Deliberately independent of P8.4 and generic hardware decode support.
  var supportsP81SystemPixels = false
  var supportsP5SystemPixels = false
}

internal enum VideoPresentationPlanner {
  static func candidates(
    signal: VideoSignalDescription, policy: UmbelVideoPolicy,
    environment: VideoEnvironmentCapabilities
  ) -> [VideoPresentationPlan] {
    let dynamic = signal.dynamicHDR
    if case .dv(let profile, _, let compatibility) = dynamic,
       profile == 8, ![1, 2, 4, 6].contains(compatibility) { return [] }
    let transfer = dynamic?.baseLayer?.transfer ?? UmbelTransferFunction(ffmpegCode: signal.transferCode)
    let color = [0, 1, 2].contains(signal.primariesCode) ? UmbelColorPrimaries.bt709 : .bt2020
    let output = VideoOutput.choose(for: transfer,
      systemShowsHDR: environment.showsHDR && policy.dynamicRange == .automatic,
      bitDepth: signal.pixels?.effectiveBits, primaries: color)
    var plans: [VideoPresentationPlan] = []
    if dynamic?.requiresSystemDisplay == true {
      if environment.supportsSystemCompressed && policy.dynamicRange == .automatic {
        if case .dv(let profile, _, let compatibility) = dynamic, profile == 5, compatibility == 0,
           environment.supportsP5SystemPixels, SystemPixelDecodeConfiguration.supports(signal.pixels),
           [0, 2].contains(signal.rangeCode) {
          plans.append(.init(route: .systemPixels, output: output, metadata: .declared, reason: nil))
        }
        plans.append(.init(route: .systemCompressed, output: output, metadata: .declared, reason: nil))
      }
      return plans
    }
    var reason: String?
    if dynamic != nil {
      reason = policy.dynamicRange == .standard ? "standardRangeRequested"
        : policy.dynamicMetadata == .compatibleBaseLayer ? "compatibleBaseLayerRequested"
        : "metadataTransportUnverified"
      if policy.dynamicRange == .automatic, policy.dynamicMetadata == .automatic,
         case .dv(let profile, _, let compatibility) = dynamic {
        if profile == 8, compatibility == 4, environment.supportsP84SystemPixels {
          plans.append(.init(route: .systemPixels, output: output, metadata: .declared, reason: nil))
        }
        if profile == 8, compatibility == 1, environment.supportsP81SystemPixels,
           SystemPixelDecodeConfiguration.supports(signal.pixels) {
          plans.append(.init(route: .systemPixels, output: output, metadata: .declared, reason: nil))
        }
      }
    }
    let base = environment.supportsHighPrecision ? output : VideoOutput.standard
    plans.append(.init(route: .metalPixels, output: base,
      metadata: dynamic == nil ? .notPresent : .baseLayerFallback,
      reason: environment.supportsHighPrecision ? reason : "targetFormatUnsupported"))
    return plans
  }
}
