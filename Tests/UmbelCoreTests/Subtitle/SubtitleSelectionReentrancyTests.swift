import CoreGraphics
import CoreMedia
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

/// Holds exactly one real decoder result before its controller consumes it.
private actor CueReadGate {
  private var armed = false
  private var held: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?

  func arm() { armed = true }

  func suspendIfArmed() async {
    guard armed else { return }
    armed = false
    await withCheckedContinuation { continuation in
      held = continuation
      observer?.resume()
      observer = nil
    }
  }

  func waitUntilHeld() async {
    guard held == nil else { return }
    await withCheckedContinuation { observer = $0 }
  }

  func release() {
    held?.resume()
    held = nil
  }
}

final class SubtitleSelectionReentrancyTests: XCTestCase {
  private struct HeldClock: HostTimeSource { var now: CMTime { .zero } }

  private let track = UmbelTrack.ID(rawValue: 4)
  private let canvas = CGSize(width: 320, height: 180)
  private var time: CMTime { CMTime(seconds: 2, preferredTimescale: 600) }

  private func controller(gate: CueReadGate) async throws -> SubtitleController {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/styled_subs.mkv")
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture))
    try await demux.open()
    let controller = SubtitleController(demux: demux) { decoder, time in
      let result = await decoder.cues(at: time)
      await gate.suspendIfArmed()
      return result
    }
    addTeardownBlock { await gate.release(); await controller.close(); await demux.close() }
    for slot in UmbelSubtitleSlot.allCases {
      try await controller.selectManually(track, for: slot)
    }
    let packet = DemuxPacket(
      trackID: track, data: Data("visible subtitle".utf8), presentationTime: .zero,
      decodeTime: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600), isKeyframe: true)
    for route in await controller.embeddedSelections { await route.receiver.receive(packet) }
    return controller
  }

  private func failSelection(_ controller: SubtitleController) async {
    do {
      try await controller.selectManually(.init(rawValue: -1))
      XCTFail("unavailable track must fail")
    } catch {}
  }

  func testFailedSelectionDoesNotEraseAnInFlightCueRead() async throws {
    let gate = CueReadGate()
    let controller = try await controller(gate: gate)
    let at = time
    await gate.arm()
    let reading = Task { await controller.cues(atClock: at) }
    await gate.waitUntilHeld()
    await failSelection(controller)
    await gate.release()
    let cues = await reading.value
    XCTAssertEqual(cues.map(\.plainText), ["visible subtitle"])
  }

  func testSameTrackSelectionDoesNotEraseAnInFlightSnapshot() async throws {
    let gate = CueReadGate()
    let controller = try await controller(gate: gate)
    let at = time, size = canvas
    await gate.arm()
    let taking = Task { await controller.snapshot(at: at, in: size, videoSize: size) }
    await gate.waitUntilHeld()
    try await controller.selectManually(track)
    await gate.release()
    let snapshot = await taking.value
    XCTAssertEqual(snapshot.count, 2, "both committed layers survive a no-op request")
  }

  func testACommittedDisableDiscardsTheOldDecoderResult() async throws {
    let gate = CueReadGate()
    let controller = try await controller(gate: gate)
    let at = time
    await gate.arm()
    let reading = Task { await controller.cues(atClock: at) }
    await gate.waitUntilHeld()
    try await controller.selectManually(nil)
    await gate.release()
    let cues = await reading.value
    XCTAssertTrue(cues.isEmpty, "a genuine replacement must reject the suspended old result")
  }

  func testFailedSelectionDuringPausedRedrawMatchesSnapshotPixels() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let gate = CueReadGate()
    let controller = try await controller(gate: gate)
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: .zero)
    let color = VideoColorDescription(matrix: .bt709, range: .limited)
    try await renderer.prepare(width: 320, height: 180, color: color)
    let buffer = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(
      width: 320, height: 180, luma: 16, cb: 128, cr: 128))
    let frame = VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 320, height: 180, color: color)
    try await renderer.enqueue(frame)
    let clock = PresentationClock(hostTime: HeldClock())
    await clock.reset(to: time)
    let presenter = PlaybackPresenter(renderer: renderer, clock: clock, subtitles: controller, compositesSubtitles: true)
    _ = try await presenter.renderVideoFrame(videoSize: canvas)
    await controller.setPlacement(.init(verticalOffset: 0.3), for: .secondary)
    await gate.arm()
    let size = canvas
    let redrawing = Task { try await presenter.renderVideoFrame(videoSize: size) }
    await gate.waitUntilHeld()
    await failSelection(controller)
    await gate.release()
    _ = try await redrawing.value

    let layers = await controller.snapshot(at: time, in: canvas, videoSize: canvas)
    XCTAssertEqual(layers.count, 2)
    let snapshot = try FrameSnapshot.image(of: frame, size: canvas, subtitles: layers, device: device)
    let bytes = [UInt8](try XCTUnwrap(snapshot.dataProvider?.data) as Data)
    var maximumDifference = 0
    func sRGB(_ code: UInt8) -> Int {
      let signal = Double(code) / 255
      let light = signal < 0.081 ? signal / 4.5 : pow((signal + 0.099) / 1.099, 1 / 0.45)
      let value = light <= 0.0031308 ? light * 12.92 : 1.055 * pow(light, 1 / 2.4) - 0.055
      return Int((value * 255).rounded())
    }
    for y in stride(from: 0, to: 180, by: 2) {
      for x in stride(from: 0, to: 320, by: 2) {
        let pixel = try await renderer.readPixel(x: x, y: y)
        let offset = (y * 320 + x) * 4
        maximumDifference = max(maximumDifference,
          abs(sRGB(pixel.b) - Int(bytes[offset])), abs(sRGB(pixel.g) - Int(bytes[offset + 1])),
          abs(sRGB(pixel.r) - Int(bytes[offset + 2])))
      }
    }
    XCTAssertLessThanOrEqual(maximumDifference, 2, "failed selection cannot leave a paused layer blank")
  }
}
