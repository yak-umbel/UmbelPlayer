import CoreMedia
import CoreVideo
import Foundation
import UmbelFFmpegSupport
import VideoToolbox

/// System decoding with original buffer attachments retained for system display.
/// No pixel rewriting or private metadata-key interpretation happens here.
internal actor SystemPixelDecodeSession: VideoFrameSource {
  private let packaged: SystemDecodeSession
  private let configuration: SystemPixelDecodeConfiguration
  private let collector = SystemPixelCollector()
  private var session: VTDecompressionSession?
  private var format: CMVideoFormatDescription?
  private var color: VideoColorDescription
  private var closed = false
  private var skips = false
  private var order: VideoPresentationOrder
  private var watermark = VideoDecodeWatermark()
  private var generation: UInt64 = 0

  init(parameters: FFmpegCodecParameters, record: FFmpegDOVIConfiguration,
       primed: HEVCParameterSets.Sets? = nil) throws {
    let admitted = try SystemPixelDecodeConfiguration(record: record,
      pixels: parameters.videoFormat.map(VideoPixelDescription.init(ffmpeg:)))
    try admitted.validate(parameters: parameters)
    configuration = admitted
    // Five 4K ten-bit surfaces can be pending around a decode watermark.
    // Keep a byte bound as well as VideoPresentationOrder's frame bound.
    order = VideoPresentationOrder(limitBytes: (admitted.isP5 ? 128 : 64) * 1024 * 1024)
    packaged = try SystemDecodeSession(parameters: parameters, record: record, primed: primed, preparesParameterSets: true)
    color = .init(matrix: .bt2020, range: admitted.isP5 ? .full : .limited,
                  transfer: record.compatibility == 4 ? .hlg : .pq, primaries: .bt2020)
  }

  func decode(_ packet: DemuxPacket, hidden: Bool) async throws -> [VideoFrame] {
    guard !closed else { return [] }
    let before = generation
    if let parameters = packet.decoderParameters {
      try configuration.validate(parameters: parameters)
    }
    let frames: [VideoFrame]
    do {
      frames = try await packaged.decode(packet, hidden: hidden)
    } catch {
      guard before == generation, !closed else { return [] }
      if case UmbelError.unsupportedCodec(let reason) = error {
        try Task.checkCancellation()
        throw UmbelError.videoRenderUnavailable(reason: "system sample packaging rejected the stream: \(reason)")
      }
      throw error
    }
    guard before == generation, !closed else { return [] }
    if !frames.isEmpty {
      // Some containers cannot establish DTS for the first few packets.
      // Decode them, but release no pixels until a real watermark arrives.
      _ = try watermark.accept(presentation: packet.presentationTime, decode: packet.decodeTime)
    }
    for frame in frames {
      guard let sample = frame.compressedSample, let description = CMSampleBufferGetFormatDescription(sample) else { continue }
      if format == nil || !CFEqual(format, description) {
        if let session {
          VTDecompressionSessionFinishDelayedFrames(session)
          VTDecompressionSessionWaitForAsynchronousFrames(session)
          VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        // Materialize old callbacks with their old signal before reconfiguring.
        try order.append(try pictures())
        try createSession(description)
      }
      if !configuration.isP5 { color = frame.color }
      guard let session else { throw UmbelError.videoRenderUnavailable(reason: "system decoder unavailable") }
      let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
        flags: hidden ? ._DoNotOutputFrame : [], frameRefcon: nil, infoFlagsOut: nil)
      guard status == noErr else { throw UmbelError.videoRenderUnavailable(reason: "system decode rejected frame: \(status)") }
      let waited = VTDecompressionSessionWaitForAsynchronousFrames(session)
      guard waited == noErr else { throw UmbelError.videoRenderUnavailable(reason: "system decode wait failed: \(waited)") }
      try order.append(try pictures())
    }
    return order.take(through: packet.decodeTime)
  }

  private func createSession(_ description: CMVideoFormatDescription) throws {
    try configuration.validate(description: description)
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { reference, _, status, _, buffer, pts, duration in
        guard let reference else { return }
        Unmanaged<SystemPixelCollector>.fromOpaque(reference).takeUnretainedValue()
          .append(status: status, buffer: buffer, pts: pts, duration: duration)
      }, decompressionOutputRefCon: Unmanaged.passUnretained(collector).toOpaque())
    var created: VTDecompressionSession?
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: configuration.outputPixelFormat,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var specification: CFDictionary?
    if configuration.isP5 {
      if #available(iOS 17, tvOS 17, macCatalyst 17, *) {
        specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
      } else {
        throw UmbelError.videoRenderUnavailable(reason: "system P5 pixels require a hardware-only decoder option unavailable on this OS")
      }
    }
    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
      decoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary,
      outputCallback: &callback, decompressionSessionOut: &created)
    guard status == noErr, let created else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel decoder creation failed: \(status)")
    }
    let propagated = VTSessionSetProperty(created,
      key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata, value: kCFBooleanTrue)
    guard propagated == noErr else {
      VTDecompressionSessionInvalidate(created)
      throw UmbelError.videoRenderUnavailable(reason: "system metadata propagation rejected: \(propagated)")
    }
    session = created
    format = description
  }

  private func pictures() throws -> [VideoFrame] {
    let received = try collector.take()
    return try received.map { decoded in
      // Read once, as a plain value: the right side of `||` is an autoclosure,
      // and it should not hold the decoded picture.
      let pixelFormat = CVPixelBufferGetPixelFormatType(decoded.buffer)
      let actual = VideoPixelDescription(cvFormat: pixelFormat)
      guard SystemPixelDecodeConfiguration.supports(actual),
            !configuration.isP5 || pixelFormat == configuration.outputPixelFormat else {
        throw UmbelError.videoRenderUnavailable(reason: "system decoder did not preserve the required pixel precision and sampling")
      }
      var frame = VideoFrame(presentationTime: decoded.pts, pixelBuffer: decoded.buffer,
        width: CVPixelBufferGetWidth(decoded.buffer), height: CVPixelBufferGetHeight(decoded.buffer), color: color)
      frame.presentationRoute = .systemPixels
      frame.duration = decoded.duration
      frame.sourcePixelDescription = frame.pixelDescription
      return frame
    }
  }

  func drain() throws -> [VideoFrame] {
    if let session {
      VTDecompressionSessionFinishDelayedFrames(session)
      VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
    try order.append(try pictures())
    return order.drain()
  }

  func flush() async {
    generation &+= 1
    if let session {
      VTDecompressionSessionWaitForAsynchronousFrames(session)
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
    format = nil
    collector.discard()
    order.reset()
    watermark.reset()
    await packaged.flush()
  }
  func renew() async throws { await flush() }
  func close() async { closed = true; await flush(); await packaged.close() }

  /// Hand the native display path the current headers, including parameter
  /// sets seen before the retained GOP. Rebuilding from the initial stream
  /// description would lose in-band updates. This packager has no decoder
  /// resources, and its flush preserves the active parameter sets.
  func compressedRecovery() async -> SystemDecodeSession {
    await packaged.flush()
    return packaged
  }
  func setSkipsNonReference(_ skips: Bool) { self.skips = skips }
  var skipsNonReference: Bool { skips }
}

private final class SystemPixelCollector: @unchecked Sendable {
  struct Picture { let buffer: CVPixelBuffer; let pts: CMTime; let duration: CMTime }
  private let lock = NSLock()
  private var frames: [Picture] = []
  private var failure: OSStatus?
  func append(status: OSStatus, buffer: CVPixelBuffer?, pts: CMTime, duration: CMTime) {
    lock.withLock {
      if status != noErr { failure = status }
      if let buffer { frames.append(.init(buffer: buffer, pts: pts, duration: duration)) }
    }
  }
  func take() throws -> [Picture] {
    try lock.withLock {
      defer { frames.removeAll(keepingCapacity: true); failure = nil }
      if let failure { throw UmbelError.videoRenderUnavailable(reason: "system decode callback failed: \(failure)") }
      return frames
    }
  }
  func discard() { lock.withLock { frames.removeAll(); failure = nil } }
}
