import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import UmbelCore

final class AsyncVideoDecodeParityTests: XCTestCase {
  func testSoftwareAndPreferredHardwareMatchSynchronousPixelsAndTiming() async throws {
    for preferHardware in [false, true] {
      for name in ["b_frames.mkv", "av1_8bit.mp4", "av1_10bit.mp4", "hevc10_white.mp4", "hdr10_pq.mp4"] {
        // A virtual machine reports AV1 hardware decoding it cannot do.
        if preferHardware, HostEnvironment.isVirtualMachine, name.hasPrefix("av1") { continue }
        let demux = try await opened(name)
        let video = try await videoTrack(demux)
        let synchronous = VideoDecodeSession(
          decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: preferHardware))
        let asynchronous = AsyncVideoDecodeSession(
          decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: preferHardware))
        var expected: [Fingerprint] = []
        var actual: [Fingerprint] = []
        while let packet = try await demux.nextPacket() {
          guard packet.trackID == video.id else { continue }
          expected += try await synchronous.decode(packet).map(Fingerprint.init)
          actual += try await asynchronous.decode(packet).map(Fingerprint.init)
        }
        expected += try await synchronous.drain().map(Fingerprint.init)
        actual += try await asynchronous.drain().map(Fingerprint.init)
        XCTAssertFalse(expected.isEmpty, name)
        XCTAssertEqual(actual, expected, "\(name), prefer hardware: \(preferHardware)")
        XCTAssertEqual(actual.map(\.time), actual.map(\.time).sorted(), "presentation order")
        let secondDrain = try await asynchronous.drain()
        XCTAssertTrue(secondDrain.isEmpty)
        await synchronous.close()
        await asynchronous.close()
      }
    }
  }

  /// Deinterlacing runs on the decoding queue here: the same pictures at the
  /// same times, from the same pixels, as when it runs in the caller's turn.
  func testDeinterlacedPicturesMatchSynchronousPixelsAndTiming() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let demux = try await opened("interlaced_tff.ts")
    let video = try await videoTrack(demux)
    let synchronous = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false),
      deinterlacer: VideoDeinterlacer(setting: DeinterlaceSwitch(), nominalFrameRate: 25))
    let asynchronous = AsyncVideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false),
      deinterlacer: VideoDeinterlacer(setting: DeinterlaceSwitch(), nominalFrameRate: 25))
    var expected: [Fingerprint] = []
    var actual: [Fingerprint] = []
    while let packet = try await demux.nextPacket() {
      guard packet.trackID == video.id else { continue }
      expected += try await synchronous.decode(packet).map(Fingerprint.init)
      actual += try await asynchronous.decode(packet).map(Fingerprint.init)
    }
    expected += try await synchronous.drain().map(Fingerprint.init)
    actual += try await asynchronous.drain().map(Fingerprint.init)
    let frames = await synchronous.decodedFrameCount
    XCTAssertGreaterThan(frames, 10)
    XCTAssertEqual(expected.count, 2 * frames, "two pictures to a frame")
    XCTAssertEqual(actual, expected)
    XCTAssertEqual(actual.map(\.time), actual.map(\.time).sorted(), "presentation order")
    await synchronous.close()
    await asynchronous.close()
  }

  func testParameterChangesKeepEveryOldAndNewFrame() async throws {
    let first = try await opened("b_frames.mkv")
    let firstVideo = try await videoTrack(first)
    let synchronous = VideoDecodeSession(
      decoder: try await first.makeVideoDecoder(for: firstVideo.id, preferHardware: false))
    let asynchronous = AsyncVideoDecodeSession(
      decoder: try await first.makeVideoDecoder(for: firstVideo.id, preferHardware: false))
    var expected: [Fingerprint] = []
    var actual: [Fingerprint] = []
    for demux in [first, try await opened("hevc10_white.mp4")] {
      let video = try await videoTrack(demux)
      let parameters = await demux.codecParameters(for: video.id)
      while var packet = try await demux.nextPacket() {
        guard packet.trackID == video.id else { continue }
        packet.decoderParameters = parameters
        expected += try await synchronous.decode(packet).map(Fingerprint.init)
        actual += try await asynchronous.decode(packet).map(Fingerprint.init)
      }
    }
    expected += try await synchronous.drain().map(Fingerprint.init)
    actual += try await asynchronous.drain().map(Fingerprint.init)
    XCTAssertEqual(actual, expected)
    XCTAssertGreaterThan(Set(actual.map(\.format)).count, 1, "8-bit and 10-bit output both survived")
    await synchronous.close()
    await asynchronous.close()
  }

  func testHiddenFramesFlushAndRenewPreserveSynchronousBehavior() async throws {
    let demux = try await opened("b_frames.mkv")
    let video = try await videoTrack(demux)
    let synchronous = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    let asynchronous = AsyncVideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: video.id, preferHardware: false))
    var packets: [DemuxPacket] = []
    while let packet = try await demux.nextPacket() {
      if packet.trackID == video.id { packets.append(packet) }
    }
    for renew in [false, true] {
      // Discard one lookahead result as a seek or decoder renewal would.
      _ = try await synchronous.decode(packets[0])
      _ = try await asynchronous.decode(packets[0])
      await synchronous.setSkipsNonReference(true)
      await asynchronous.setSkipsNonReference(true)
      if renew {
        try await synchronous.renew()
        try await asynchronous.renew()
      } else {
        await synchronous.flush()
        await asynchronous.flush()
      }
      let skipping = await asynchronous.skipsNonReference
      XCTAssertFalse(skipping)
      var expected: [Fingerprint] = []
      var actual: [Fingerprint] = []
      for packet in packets {
        let hidden = packet.presentationTime.seconds < 2
        expected += try await synchronous.decode(packet, hidden: hidden).map(Fingerprint.init)
        actual += try await asynchronous.decode(packet, hidden: hidden).map(Fingerprint.init)
      }
      expected += try await synchronous.drain().map(Fingerprint.init)
      actual += try await asynchronous.drain().map(Fingerprint.init)
      XCTAssertEqual(actual, expected)
      await synchronous.flush()
      await asynchronous.flush()
    }
    await synchronous.close()
    await asynchronous.close()
  }

  private func opened(_ name: String) async throws -> DemuxSession {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
    let demux = DemuxSession(source: try UmbelFileSource(url: url))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    return demux
  }

  private func videoTrack(_ demux: DemuxSession) async throws -> UmbelTrack {
    let tracks = await demux.tracks
    return try XCTUnwrap(tracks.first { $0.kind == .video })
  }
}

/// Compare active pixel rows, excluding uninitialized pool padding.
private struct Fingerprint: Equatable {
  let time: Double
  let width: Int
  let height: Int
  let format: OSType
  let color: VideoColorDescription
  let aspect: Double
  let bytes: Data

  init(_ frame: VideoFrame) throws {
    time = frame.presentationTime.seconds
    width = frame.width
    height = frame.height
    color = frame.color
    aspect = frame.pixelAspectRatio
    let buffer = try XCTUnwrap(frame.pixelBuffer)
    format = CVPixelBufferGetPixelFormatType(buffer)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let sampleBytes = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1
    var pixels = Data()
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * sampleBytes * (plane == 0 ? 1 : 2)
      for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
        pixels.append((base + row * stride).assumingMemoryBound(to: UInt8.self), count: rowBytes)
      }
    }
    bytes = pixels
  }
}
