import CoreMedia
import UmbelFFmpegSupport
import XCTest
@testable import UmbelCore

private actor RecoverySource: VideoFrameSource {
  enum Failure { case video, cancellation, delayedVideo }
  let failure: Failure?
  let compressed: Bool
  private(set) var packets: [Double] = []
  init(_ failure: Failure? = nil, compressed: Bool = false) {
    self.failure = failure
    self.compressed = compressed
  }
  func decode(_ packet: DemuxPacket, hidden: Bool) throws -> [VideoFrame] {
    packets.append(packet.presentationTime.seconds)
    if let failure {
      if failure == .cancellation { throw CancellationError() }
      if failure == .video { throw UmbelError.videoRenderUnavailable(reason: "systemRejectedStream") }
    }
    if compressed {
      var sample: CMSampleBuffer?
      CMSampleBufferCreateReady(allocator: nil, dataBuffer: nil, formatDescription: nil, sampleCount: 0,
        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sample)
      return [VideoFrame(presentationTime: packet.presentationTime, compressed: sample!,
        width: 4, height: 4, color: .init(matrix: .bt709, range: .limited), isShown: !hidden)]
    }
    if hidden { return [] }
    let buffer = VideoFrame.makeTestPixelBuffer(width: 4, height: 4, luma: 100, cb: 128, cr: 128)!
    return [VideoFrame(presentationTime: packet.presentationTime, pixelBuffer: buffer,
      width: 4, height: 4, color: .init(matrix: .bt709, range: .limited))]
  }
  func drain() throws -> [VideoFrame] {
    if failure == .delayedVideo { throw UmbelError.videoRenderUnavailable(reason: "delayed system decode failed") }
    return []
  }
  func flush() {}
  func renew() throws {}
  func close() {}
  func setSkipsNonReference(_ skips: Bool) {}
  var skipsNonReference: Bool { false }
}

private actor RecoveryFactoryGate {
  private var held: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  func hold() async {
    await withCheckedContinuation { held = $0; observer?.resume(); observer = nil }
  }
  func waitUntilHeld() async {
    if held != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() { held?.resume(); held = nil }
}

private actor RejectingVideoRenderer: VideoRenderer {
  func prepare(width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription) async throws {}
  func enqueue(_ frame: VideoFrame) throws { throw UmbelError.videoRenderUnavailable(reason: "system output refused sample") }
  func presentFrame(at time: CMTime) async throws -> PresentedFrame? { nil }
  func flush() async {}
  var queueDepth: Int { 0 }
  var totalDroppedFrames: Int { 0 }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

final class VideoRouteRecoveryTests: XCTestCase {
  func testSeekDuringResumeTimeReadCannotInstallThePreviousCompressedCutoff() async throws {
    let gate = RecoveryFactoryGate()
    let path = VideoPath(primary: RecoverySource(.video), fallback: { RecoverySource(compressed: true) },
      fallbackPlan: .init(route: .systemCompressed, output: .pq, metadata: .declared,
        reason: "systemPixelDecodeUnavailable"), observation: nil, prepare: { _ in }, resumeTime: {
          await gate.hold()
          return CMTime(value: 10, timescale: 1)
        })
    let first = packet(0, key: true)
    let recovering = Task { try await path.decode(first, hidden: false) }
    await gate.waitUntilHeld()
    let release = Task {
      try? await Task.sleep(nanoseconds: 20_000_000)
      await gate.release()
    }
    await path.flush()
    await release.value
    let stale = try await recovering.value
    XCTAssertTrue(stale.isEmpty)
    let fresh = try await path.decode(packet(0, key: true), hidden: false)
    XCTAssertTrue(try XCTUnwrap(fresh.first).isShown, "a backward seek must discard the previous resume cutoff")
    await path.close()
  }

  func testCompressedRecoveryKeepsDependenciesAndHidesReorderedPicturesBeforeResumeTime() async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/dv_p5.mp4")
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let found = await demux.codecParameters(for: track.id)
    let parameters = try XCTUnwrap(found)
    var packets: [DemuxPacket] = []
    while packets.count < 16, var packet = try await demux.nextPacket() {
      if packet.trackID == track.id {
        packet.decoderParameters = parameters
        packets.append(packet)
      }
    }
    XCTAssertEqual(packets.count, 16)
    let cutoff = CMTime(value: 5, timescale: 25)
    let compressed = try SystemDecodeSession(parameters: parameters, record: XCTUnwrap(parameters.dovi))
    let path = VideoPath(primary: RecoverySource(.video), fallback: { compressed },
      fallbackPlan: .init(route: .systemCompressed, output: .pq, metadata: .declared,
        reason: "systemPixelDecodeUnavailable"), observation: nil, prepare: { _ in }, resumeTime: { cutoff })
    for packet in packets {
      let frames = try await path.decode(packet, hidden: false)
      let frame = try XCTUnwrap(frames.first, "every compressed dependency must reach the display decoder")
      XCTAssertEqual(frame.presentationTime, packet.presentationTime)
      XCTAssertNotNil(frame.compressedSample)
      XCTAssertEqual(frame.isShown, packet.presentationTime >= cutoff)
    }
    await path.close()
  }

  func testFallbackStillRejectsLaterConfigurationsWithoutACompatibleBaseLayer() async throws {
    for name in ["dv_p81.mp4", "dv_p5.mp4"] {
      let changed = try await parameters(name, removeBaseLayer: name == "dv_p81.mp4")
      let base = RecoverySource()
      let path = VideoPath(primary: RecoverySource(.video), fallback: { base },
        fallbackPlan: .init(route: .metalPixels, output: .pq,
          metadata: .baseLayerFallback, reason: "systemRejectedStream"), observation: nil, prepare: { _ in })
      _ = try await path.decode(packet(0, key: true), hidden: false)
      var next = packet(1, key: true)
      next.decoderParameters = changed
      do {
        _ = try await path.decode(next, hidden: false)
        XCTFail("an established fallback cannot decode content without a compatible base layer")
      } catch UmbelError.unsupportedDynamicHDR {}
      let accepted = await base.packets
      XCTAssertEqual(accepted, [0], "invalid content must not reach the base-layer decoder")
      await path.close()
    }
  }

  func testFallbackAllowsAChangeToOrdinaryVideo() async throws {
    let changed = try await parameters("hdr10_pq.mp4")
    XCTAssertNil(changed.dovi)
    let path = VideoPath(primary: RecoverySource(.video), fallback: { RecoverySource() },
      fallbackPlan: .init(route: .metalPixels, output: .pq,
        metadata: .baseLayerFallback, reason: "systemRejectedStream"), observation: nil, prepare: { _ in })
    _ = try await path.decode(packet(0, key: true), hidden: false)
    var next = packet(1, key: true)
    next.decoderParameters = changed
    let frames = try await path.decode(next, hidden: false)
    XCTAssertEqual(frames.map(\.presentationTime), [CMTime(value: 1, timescale: 25)])
    await path.close()
  }

  private func parameters(_ name: String, removeBaseLayer: Bool = false) async throws -> FFmpegCodecParameters {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    var data = try Data(contentsOf: fixture)
    if removeBaseLayer {
      let box = try XCTUnwrap(data.range(of: Data("dvvC".utf8)))
      data[box.upperBound + 3] &= 0xfe
    }
    let demux = DemuxSession(source: MemorySource(data: data))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let parameters = await demux.codecParameters(for: track.id)
    return try XCTUnwrap(parameters)
  }

  func testDisplayFailureCannotFallbackWhenTheLatestConfigurationHasNoBaseLayer() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/dv_p81.mp4")
    var data = try Data(contentsOf: fixture)
    let box = try XCTUnwrap(data.range(of: Data("dvvC".utf8)))
    data[box.upperBound + 3] &= 0xfe
    let demux = DemuxSession(source: MemorySource(data: data))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let tracks = await demux.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video })
    let parameters = await demux.codecParameters(for: track.id)
    XCTAssertEqual(parameters?.dovi?.hasBaseLayer, false)
    let path = VideoPath(primary: RecoverySource(), fallback: {
      XCTFail("a source without a compatible base layer must not create a fallback")
      return RecoverySource()
    }, fallbackPlan: .init(route: .metalPixels, output: .pq,
      metadata: .baseLayerFallback, reason: "systemRejectedStream"), observation: nil, prepare: { _ in })
    var first = packet(0, key: true)
    first.decoderParameters = parameters
    _ = try await path.decode(first, hidden: false)
    do {
      _ = try await path.recoverDisplayFailure(UmbelError.videoRenderUnavailable(reason: "display rejected sample"))
      XCTFail("display failure cannot invent a compatible base layer")
    } catch UmbelError.unsupportedDynamicHDR {}
    await path.close()
  }

  func testRendererRefusalFeedsTheSameBoundedRecoveryTransaction() async throws {
    let primary = RecoverySource(), base = RecoverySource()
    let path = VideoPath(primary: primary, fallback: { base },
      fallbackPlan: .init(route: .metalPixels, output: .standardLinear, metadata: .baseLayerFallback, reason: "systemRejectedStream"),
      observation: nil, prepare: { _ in })
    let decoded = try await path.decode(packet(0, key: true), hidden: false)
    let recovered = try await VideoPath.deliver(try XCTUnwrap(decoded.first), to: RejectingVideoRenderer(),
      source: path, validate: {})
    XCTAssertTrue(recovered)
    let resumed = try await path.decode(packet(1, key: false), hidden: false)
    XCTAssertEqual(resumed.map(\.presentationTime), [.zero, CMTime(value: 1, timescale: 25)])
  }
  func testSeekFlushDuringFallbackInstallsAFreshDecoderWithoutReplayingOldPictures() async throws {
    let primary = RecoverySource(.video), base = RecoverySource(), gate = RecoveryFactoryGate()
    let path = VideoPath(primary: primary, fallback: { await gate.hold(); return base },
      fallbackPlan: .init(route: .metalPixels, output: .standardLinear, metadata: .baseLayerFallback, reason: "systemRejectedStream"),
      observation: nil, prepare: { _ in })
    let firstPacket = packet(0, key: true)
    let decoding = Task { try await path.decode(firstPacket, hidden: false) }
    await gate.waitUntilHeld()
    let released = Task {
      try? await Task.sleep(nanoseconds: 20_000_000)
      await gate.release()
    }
    await path.flush()
    await released.value
    let stale = try await decoding.value
    XCTAssertTrue(stale.isEmpty)
    let fresh = try await path.decode(packet(25, key: true), hidden: false)
    XCTAssertEqual(fresh.first?.presentationTime, CMTime(value: 1, timescale: 1))
  }
  func testDelayedDecodeFailureReplaysTheRetainedPicturesBeforeEndOfStream() async throws {
    let primary = RecoverySource(.delayedVideo), base = RecoverySource()
    let path = VideoPath(primary: primary, fallback: { base },
      fallbackPlan: .init(route: .metalPixels, output: .standardLinear, metadata: .baseLayerFallback, reason: "systemRejectedStream"),
      observation: nil, prepare: { _ in })
    _ = try await path.decode(packet(0, key: true), hidden: false)
    _ = try await path.decode(packet(1, key: false), hidden: false)
    let replayed = try await path.drain()
    XCTAssertEqual(replayed.map(\.presentationTime), [.zero, CMTime(value: 1, timescale: 25)])
  }
  private func packet(_ value: Int, key: Bool) -> DemuxPacket {
    .init(trackID: .init(rawValue: 0), data: Data([UInt8(truncatingIfNeeded: value)]),
      presentationTime: CMTime(value: Int64(value), timescale: 25),
      decodeTime: CMTime(value: Int64(value), timescale: 25), duration: CMTime(value: 1, timescale: 25), isKeyframe: key)
  }

  func testSystemFailureReplaysFromKeyframeAndOnlyFallsBackOnce() async throws {
    let primary = RecoverySource(.video), base = RecoverySource()
    let observation = VideoPresentationObservation(diagnostics: nil)
    let path = VideoPath(primary: primary, fallback: { base },
      fallbackPlan: .init(route: .metalPixels, output: .hlg, metadata: .baseLayerFallback, reason: "systemRejectedStream"),
      observation: observation, prepare: { _ in })
    let recovered = try await path.decode(packet(0, key: true), hidden: false)
    XCTAssertEqual(recovered.first?.presentationTime, .zero)
    _ = try await path.decode(packet(1, key: false), hidden: false)
    let firstPackets = await primary.packets
    let basePackets = await base.packets
    XCTAssertEqual(firstPackets, [0])
    XCTAssertEqual(basePackets.count, 2)
    XCTAssertEqual(observation.snapshot.metadata, .baseLayerFallback)
  }

  func testMissingGOPWaitsForKeyframeInsteadOfDecodingAnArbitraryPacket() async throws {
    let primary = RecoverySource(.video), base = RecoverySource()
    let path = VideoPath(primary: primary, fallback: { base },
      fallbackPlan: .init(route: .metalPixels, output: .standardLinear, metadata: .baseLayerFallback, reason: "systemRejectedStream"),
      observation: nil, prepare: { _ in })
    let withheld = try await path.decode(packet(1, key: false), hidden: false)
    XCTAssertTrue(withheld.isEmpty)
    let recovered = try await path.decode(packet(2, key: true), hidden: false)
    XCTAssertEqual(recovered.first?.presentationTime, CMTime(value: 2, timescale: 25))
    let basePackets = await base.packets
    XCTAssertEqual(basePackets, [0.08])
  }

  func testCancellationDoesNotCauseQualityFallback() async throws {
    let primary = RecoverySource(.cancellation), base = RecoverySource()
    let path = VideoPath(primary: primary, fallback: { base },
      fallbackPlan: .init(route: .metalPixels, output: .standard, metadata: .baseLayerFallback, reason: "systemRejectedStream"),
      observation: nil, prepare: { _ in })
    do {
      _ = try await path.decode(packet(0, key: true), hidden: false)
      XCTFail("cancelled decode was accepted")
    } catch is CancellationError {}
    let basePackets = await base.packets
    XCTAssertTrue(basePackets.isEmpty)
  }
}
