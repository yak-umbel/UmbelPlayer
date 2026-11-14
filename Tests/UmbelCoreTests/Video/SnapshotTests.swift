import CoreGraphics
import CoreMedia
@preconcurrency import Metal  // MTLDevice is not Sendable in the older SDKs
import XCTest
@testable import UmbelCore

final class SnapshotTests: XCTestCase {
  private final class ReadySink: SampleBufferSink, @unchecked Sendable {
    func enqueue(_ buffer: CMSampleBuffer) {}
    func flush() {}
    var hasFailed: Bool { false }
    var isReadyForMoreMediaData: Bool { true }
  }

  private final class HeldTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func session(for name: String) async throws -> PlaybackSession {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture(name)), videoRenderer: renderer, hostTime: HeldTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    return session
  }

  private func showFirstPicture(_ session: PlaybackSession) async throws {
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("no picture was presented")
  }

  private func pixels(_ image: CGImage) throws -> [UInt8] {
    let data = try XCTUnwrap(image.dataProvider?.data)
    return [UInt8](data as Data)
  }

  func testSnapshotBeforeAFrameIsShownReportsUnavailability() async throws {
    let session = try await session(for: "hevc10_white.mp4")
    do {
      _ = try await session.snapshot()
      XCTFail("there is no shown frame yet")
    } catch UmbelError.snapshotUnavailable {
      // The caller can distinguish an unavailable picture from a rendering failure.
    }
  }

  func testSnapshotUsesTheSourceDisplaySizeAndSRGB() async throws {
    let session = try await session(for: "hevc10_white.mp4")
    try await showFirstPicture(session)
    let image = try await session.snapshot()
    let tracks = await session.tracks
    let track = try XCTUnwrap(tracks.first { $0.kind == .video }?.video)
    XCTAssertEqual(image.width, track.displayWidth)
    XCTAssertEqual(image.height, track.height)
    XCTAssertEqual(image.bitsPerComponent, 8)
    XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
    let bytes = try pixels(image)
    let center = (image.height / 2 * image.width + image.width / 2) * 4
    XCTAssertGreaterThan(bytes[center], 230)
    XCTAssertGreaterThan(bytes[center + 1], 230)
    XCTAssertGreaterThan(bytes[center + 2], 230)
  }

  func testHDRSnapshotIsEightBitSRGB() async throws {
    let session = try await session(for: "hdr10_pq.mp4")
    try await showFirstPicture(session)
    let image = try await session.snapshot()
    XCTAssertEqual(image.bitsPerComponent, 8)
    XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
  }

  func testSubtitlesCanBeIncludedOrExcluded() async throws {
    let session = try await session(for: "styled_subs.mkv")
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 4))
    try await session.seek(to: CMTime(seconds: 0.6, preferredTimescale: 600))
    try await showFirstPicture(session)

    let withSubtitles = try await session.snapshot()
    let withoutSubtitles = try await session.snapshot(includingSubtitles: false)
    XCTAssertEqual(withSubtitles.width, withoutSubtitles.width)
    let withPixels = try pixels(withSubtitles)
    let withoutPixels = try pixels(withoutSubtitles)
    XCTAssertNotEqual(withPixels, withoutPixels)
  }

  func testSystemDecodedPictureReportsWhyItCannotBeCaptured() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let main = try OffscreenVideoRenderer(
      device: device, tolerance: CMTime(seconds: 0.02, preferredTimescale: 600))
    let system = try SampleBufferVideoRenderer(
      sink: ReadySink(), device: device,
      tolerance: CMTime(seconds: 0.02, preferredTimescale: 600), systemShowsDV: true)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("dv_p5.mp4")),
      videoRenderer: SwitchingVideoRenderer(main: main, pictureInPicture: system),
      hostTime: HeldTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await showFirstPicture(session)

    do {
      _ = try await session.snapshot()
      XCTFail("compressed pictures cannot be read back")
    } catch UmbelError.snapshotUnavailable(let reason) {
      XCTAssertTrue(reason.contains("system"))
    }
  }
}
