import Foundation
import CoreMedia

/// Which session a video track's packets go to: decoded here — a DV base
/// layer with the colour its configuration names — or packaged for the
/// system to decode and show, for DV without a base layer of its own.
internal enum VideoRoute {
  static func session(
    for track: UmbelTrack, demux: DemuxSession, renderer: any VideoRenderer,
    mode: UmbelVideoDecodingMode = .synchronous, decoder configuration: UmbelVideoDecoderConfiguration = .init(),
    deinterlacing: DeinterlaceSwitch? = nil,
    diagnostics: UmbelPlaybackDiagnostics? = nil,
    policy requestedPolicy: UmbelVideoPolicy? = nil, observation: VideoPresentationObservation? = nil,
    resumeTime: @escaping @Sendable () async -> CMTime = { .invalid }
  ) async throws -> any VideoFrameSource {
    let dynamic = track.video?.dynamicHDR
    let constraint = await (renderer as? any VideoPresentationObserving)?.dynamicRangeConstraint ?? .automatic
    let policy = requestedPolicy ?? .init(dynamicRange: constraint)
    if constraint == .standard, policy.dynamicRange != .standard {
      throw UmbelError.videoRenderUnavailable(reason: "video policy conflicts with renderer standard-range constraint")
    }
    await (renderer as? any VideoPresentationObserving)?.setVideoPolicy(policy)
    let supportsCompressed = await (renderer as? any SystemDecodedVideoShowing)?.showsSystemDecodedDV ?? false
    let supportsPixels = await (renderer as? any SystemPixelVideoShowing)?.showsP84SystemPixels ?? false
    let supportsP81 = await (renderer as? any SystemPixelVideoShowing)?.showsP81SystemPixels ?? false
    let supportsP5 = await (renderer as? any SystemPixelVideoShowing)?.showsP5SystemPixels ?? false
    let signal = track.video?.signal ?? .init(
      transferCode: track.video?.transfer == .hlg ? 18 : track.video?.transfer == .pq ? 16 : 1,
      dynamicHDR: dynamic)
    let plans = VideoPresentationPlanner.candidates(signal: signal, policy: policy,
      environment: .init(showsHDR: VideoOutput.systemShowsHDR,
        supportsP84SystemPixels: supportsPixels && track.video?.rotation == UmbelVideoRotation.none,
        supportsSystemCompressed: supportsCompressed,
        supportsP81SystemPixels: supportsP81 && track.video?.rotation == UmbelVideoRotation.none,
        supportsP5SystemPixels: supportsP5 && track.video?.rotation == UmbelVideoRotation.none))
    if dynamic?.requiresSystemDisplay == true, !(renderer is any SystemDecodedVideoShowing) {
      throw UmbelError.displayLayerRequired
    }
    guard let plan = plans.first else { throw UmbelError.unsupportedDynamicHDR(dynamic?.label ?? "video") }
    observation?.select(plan)
    func compatibleSession() async throws -> any VideoFrameSource {
      let decoder = try await demux.makeVideoDecoder(for: track.id, configuration: configuration)
      let deinterlacer = deinterlacing.map {
        VideoDeinterlacer(setting: $0, nominalFrameRate: track.video?.nominalFrameRate, diagnostics: diagnostics)
      }
      switch mode {
      case .synchronous:
        return VideoDecodeSession(decoder: decoder, baseLayer: dynamic?.baseLayer, deinterlacer: deinterlacer)
      case .asynchronous:
        return AsyncVideoDecodeSession(decoder: decoder, baseLayer: dynamic?.baseLayer, deinterlacer: deinterlacer)
      }
    }
    guard plan.route.isSystem else { return try await compatibleSession() }
    guard track.codecName == "hevc",
          let parameters = await demux.codecParameters(for: track.id),
          let record = parameters.dovi else {
      throw UmbelError.unsupportedDynamicHDR(dynamic?.label ?? "video")
    }
    let primed = HEVCParameterSets.hvcCHasArrays(parameters.extradata)
      ? nil : await primedParameterSets(demux: demux, track: track.id, extradata: parameters.extradata)
    if plan.route == .systemPixels {
      if let compressed = plans.last, compressed.route == .systemCompressed {
        let fallbackPlan = VideoPresentationPlan(route: .systemCompressed, output: compressed.output,
          metadata: .declared, reason: "systemPixelDecodeUnavailable")
        let primary: SystemPixelDecodeSession
        do {
          primary = try SystemPixelDecodeSession(parameters: parameters, record: record, primed: primed)
        } catch UmbelError.videoRenderUnavailable(let reason) {
          observation?.noteSystemFailure(reason)
          observation?.select(fallbackPlan)
          return try SystemDecodeSession(parameters: parameters, record: record, primed: primed)
        }
        return VideoPath(primary: primary, fallback: {
          await primary.compressedRecovery()
        }, fallbackPlan: fallbackPlan, observation: observation, prepare: { chosen in
          await renderer.flush()
          try await renderer.prepare(for: track, plan: chosen)
        }, resumeTime: resumeTime)
      }
      guard let base = plans.last, base.route == .metalPixels else {
        return try SystemPixelDecodeSession(parameters: parameters, record: record, primed: primed)
      }
      let fallbackPlan = VideoPresentationPlan(route: base.route, output: base.output,
        metadata: .baseLayerFallback, reason: "systemRejectedStream")
      let primary: SystemPixelDecodeSession
      do {
        primary = try SystemPixelDecodeSession(parameters: parameters, record: record, primed: primed)
      } catch UmbelError.videoRenderUnavailable(let reason) {
        observation?.noteSystemFailure(reason)
        observation?.select(fallbackPlan)
        return try await compatibleSession()
      } catch UmbelError.unsupportedCodec(let reason) {
        observation?.noteSystemFailure(reason)
        observation?.select(fallbackPlan)
        return try await compatibleSession()
      }
      return VideoPath(primary: primary, fallback: {
        let decoder = try await demux.makeVideoDecoder(for: track.id, configuration: configuration)
        let baseLayer: UmbelDVBaseLayer?
        switch decoder.parameters?.dovi?.compatibility {
        case 1, 6: baseLayer = .hdr10
        case 4: baseLayer = .hlg
        case 2: baseLayer = .sdr
        default: baseLayer = nil
        }
        if mode == .asynchronous { return AsyncVideoDecodeSession(decoder: decoder, baseLayer: baseLayer) }
        return VideoDecodeSession(decoder: decoder, baseLayer: baseLayer)
      }, fallbackPlan: fallbackPlan, observation: observation, prepare: { chosen in
        await renderer.flush()
        try await renderer.prepare(for: track, plan: chosen)
      }, resumeTime: resumeTime)
    }
    return try SystemDecodeSession(parameters: parameters, record: record, primed: primed)
  }

  /// Parameter sets from the stream's first pictures, for a file that
  /// carries them only there and none in its hvcC: a seek before playing
  /// lands on a keyframe without them. Read as the film opens, before
  /// playback reads anything, and sought back to the start after — so only
  /// where the source can seek.
  private static func primedParameterSets(
    demux: DemuxSession, track: UmbelTrack.ID, extradata: Data
  ) async -> HEVCParameterSets.Sets? {
    guard await demux.isSeekable else { return nil }
    let lengthSize = extradata.first == 1 ? HEVCParameterSets.lengthSize(ofHvcC: extradata) : nil
    var found: HEVCParameterSets.Sets?
    for _ in 0..<64 {
      guard let packet = try? await demux.nextPacket() else { break }
      guard packet.trackID == track else { continue }
      found = HEVCParameterSets.parameterSets(
        in: HEVCParameterSets.units(in: packet.data, lengthSize: lengthSize))
      if found != nil { break }
    }
    try? await demux.seek(to: .zero)
    return found
  }
}
