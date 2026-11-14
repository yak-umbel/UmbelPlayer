import Foundation
import Metal

/// A point-in-time view of the submitted video, not the panel's scanout format.
public struct UmbelVideoPresentationStatus: Sendable, Equatable {
  public internal(set) var route: UmbelVideoPresentationRoute?
  public internal(set) var source: VideoPixelDescription?
  public internal(set) var decoded: VideoPixelDescription?
  public internal(set) var color: VideoColorDescription?
  public internal(set) var chromaLocationCode: Int32?
  public internal(set) var outputFormat: String?
  public internal(set) var outputEffectiveBits: Int?
  public internal(set) var outputStorageBits: Int?
  public internal(set) var metadata: UmbelDynamicMetadataStatus = .unknown
  public internal(set) var qualityChanges: [String] = []
  public internal(set) var reason: String?
  public internal(set) var routeGeneration: UInt64 = 0
  public internal(set) var output = "video"
  /// Runtime delivery alone never sets this flag. Visual validation is separate.
  public var effectValidated: Bool { false }
  internal init() {}
}

/// Shared observations survive disabled diagnostics and bounded history eviction.
internal final class VideoPresentationObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var current = UmbelVideoPresentationStatus()
  private var plan: VideoPresentationPlan?
  private var diagnostics: UmbelPlaybackDiagnostics?

  init(diagnostics: UmbelPlaybackDiagnostics?) { self.diagnostics = diagnostics }
  var snapshot: UmbelVideoPresentationStatus { lock.withLock { current } }
  var selectedPlan: VideoPresentationPlan? { lock.withLock { plan } }

  func reset() { lock.withLock { current = .init(); plan = nil } }

  /// Called only for the built-in primary decoder's controlled error reasons.
  func noteSystemFailure(_ reason: String) {
    lock.withLock {
      diagnostics?.record("video_route_transition", values: ["routeGeneration": Double(current.routeGeneration)],
        labels: ["stage": "systemDecode", "reason": reason, "outcome": "attemptCompatibleBaseLayer"])
    }
  }

  func select(_ plan: VideoPresentationPlan) {
    lock.withLock {
      if self.plan != plan { current.routeGeneration &+= 1 }
      self.plan = plan
      current.route = plan.route
      current.metadata = plan.metadata
      current.reason = plan.reason
      diagnostics?.record("video_plan_selected", values: ["routeGeneration": Double(current.routeGeneration)],
        labels: ["route": plan.route.rawValue, "metadata": plan.metadata.rawValue,
                 "reason": plan.reason ?? "none"])
    }
  }

  func observe(_ frame: VideoFrame, output: String, target: VideoOutput? = nil,
               actual: VideoPixelDescription? = nil, metadata: UmbelDynamicMetadataStatus? = nil,
               reason: String? = nil) {
    lock.withLock {
      var next = current
      next.route = frame.presentationRoute
      next.source = frame.sourcePixelDescription ?? frame.pixelDescription
      next.decoded = frame.pixelDescription
      next.color = frame.color
      next.chromaLocationCode = frame.chromaLocationCode
      next.output = output
      next.metadata = metadata ?? (frame.dynamicMetadataInvalidated ? .invalidatedByProcessing
        : frame.presentationRoute.isSystem ? .submittedToSystem
        : plan?.metadata == .baseLayerFallback ? .baseLayerFallback
        : frame.hasDynamicMetadata ? .baseLayerFallback : plan?.metadata ?? .notPresent)
      next.outputFormat = actual?.format ?? target.map { String(describing: $0.pixelFormat) }
      next.outputEffectiveBits = actual?.effectiveBits ?? target.flatMap { $0 == .standard ? 8 : nil }
      next.outputStorageBits = actual?.storageBits ?? target.map {
        $0.pixelFormat == .rgba32Float ? 32 : $0.pixelFormat == .rgba16Float ? 16 : 8
      }
      next.reason = reason ?? frame.conversionReason ?? plan?.reason
      var changes: [String] = []
      if let a = next.source?.effectiveBits, let b = next.decoded?.effectiveBits, a > b {
        changes.append("bitDepthReduction")
      }
      if let a = next.source?.effectiveBits, let b = next.outputEffectiveBits, a > b,
         !changes.contains("bitDepthReduction") { changes.append("bitDepthReduction") }
      let order = ["4:4:4": 3, "4:2:2": 2, "4:2:0": 1, "4:1:1": 0]
      if let a = next.source?.chromaSubsampling.flatMap({ order[$0] }),
         let b = next.decoded?.chromaSubsampling.flatMap({ order[$0] }), a > b {
        changes.append("chromaSubsampling")
      }
      if frame.color.isHDR, target?.isStandard == true { changes.append("dynamicRangeMapping") }
      if frame.color.primaries == .bt2020, target?.isStandard == true, target?.encoding != .standardLinear2020 {
        changes.append("gamutMapping")
      }
      if next.metadata == .baseLayerFallback || next.metadata == .invalidatedByProcessing {
        changes.append("dynamicMetadataNotApplied")
      }
      if next.source?.isFloatingPoint == true, next.decoded?.isFloatingPoint == false {
        changes.append("floatingPointToInteger")
      }
      if target?.pixelFormat == .rgba16Float,
         (next.source?.effectiveBits ?? 0) > 10 ||
          (target?.pixelFormat == .rgba16Float && next.source?.isFloatingPoint == true && (next.source?.storageBits ?? 0) > 16) {
        changes.append("floatingPointQuantization")
      }
      next.qualityChanges = changes
      if !changes.isEmpty, next.reason == nil { next.reason = "conversionFormatConstraint" }
      guard next != current else { return }
      current = next
      var labels = ["output": output, "route": frame.presentationRoute.rawValue,
        "sourceFormat": next.source?.format ?? "unknown", "decodedFormat": next.decoded?.format ?? "unknown",
        "outputFormat": next.outputFormat ?? "unknown", "metadata": next.metadata.rawValue,
        "changes": changes.joined(separator: ","), "reason": next.reason ?? "none"]
      labels["sourceBits"] = next.source?.effectiveBits.map(String.init) ?? "unknown"
      labels["outputBits"] = next.outputEffectiveBits.map(String.init) ?? "unknown"
      labels["outputStorageBits"] = next.outputStorageBits.map(String.init) ?? "unknown"
      labels["transferCode"] = String(frame.color.transferCode)
      labels["primariesCode"] = frame.color.primariesCode.map(String.init) ?? "inferred"
      labels["matrixCode"] = frame.color.matrixCode.map(String.init) ?? "inferred"
      labels["range"] = frame.color.range.rawValue
      labels["chromaLocationCode"] = String(frame.chromaLocationCode)
      diagnostics?.record(changes.isEmpty ? "video_format_observed" : "video_quality_changed",
        values: ["routeGeneration": Double(next.routeGeneration), "framePTS": frame.presentationTime.seconds], labels: labels)
    }
  }
}

internal protocol VideoPresentationObserving: Sendable {
  func setVideoPresentationObservation(_ observation: VideoPresentationObservation?, output: String) async
  var dynamicRangeConstraint: UmbelDynamicRange { get async }
  func setVideoPolicy(_ policy: UmbelVideoPolicy) async
}

extension VideoPresentationObserving {
  var dynamicRangeConstraint: UmbelDynamicRange { get async { .automatic } }
  func setVideoPolicy(_ policy: UmbelVideoPolicy) async {}
}
