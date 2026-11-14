import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

final class ThumbnailTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func generator(_ name: String = "seek_grid.mp4") -> UmbelThumbnailGenerator {
    let url = fixture(name)
    return UmbelThumbnailGenerator { try UmbelFileSource(url: url) }
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 60_000)
  }

  private func brightness(_ image: CGImage) throws -> UInt8 {
    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
    return bytes[image.height / 2 * image.bytesPerRow + image.width / 2 * 4]
  }

  func testSeeksToFirstPictureAtOrAfterTargetAndReportsActualTime() async throws {
    let preview = generator()
    let flash = try await preview.thumbnail(at: time(3.015))
    let dark = try await preview.thumbnail(at: time(3.515))
    XCTAssertEqual(flash.presentationTime.seconds, 3 + 1.0 / 30, accuracy: 0.001)
    XCTAssertEqual(dark.presentationTime.seconds, 3.5 + 1.0 / 30, accuracy: 0.001)
    XCTAssertGreaterThan(try brightness(flash.image), 220)
    XCTAssertLessThan(try brightness(dark.image), 30)
    XCTAssertEqual(flash.image.width, 240)
    XCTAssertEqual(flash.image.height, 180)
  }

  func testLastPictureAtEndAndNoUpscaling() async throws {
    let preview = generator("sync_check.mp4")
    let end = try await preview.thumbnail(at: time(6), maximumSize: CGSize(width: 900, height: 900))
    XCTAssertEqual(end.presentationTime.seconds, 6 - 1.0 / 30, accuracy: 0.001)
    XCTAssertEqual(end.image.width, 320)
    XCTAssertEqual(end.image.height, 240)
  }

  func testFitsDisplayAspectWithinPixelBounds() async throws {
    let image = try await generator("anamorphic.ts").thumbnail(
      at: time(0.5), maximumSize: CGSize(width: 120, height: 120)).image
    XCTAssertEqual(image.width, 120)
    XCTAssertEqual(Double(image.width) / Double(image.height), 16.0 / 9, accuracy: 0.02)
  }

  func testRejectsInvalidInputsBeforeOpeningSource() async throws {
    let source = ThumbnailProbeSource(data: Data())
    let preview = UmbelThumbnailGenerator { await source.recordFactory(); return source }
    for invalid in [CMTime.invalid, .indefinite, .positiveInfinity, time(-1)] {
      do { _ = try await preview.thumbnail(at: invalid); XCTFail("invalid time accepted") }
      catch UmbelThumbnailError.invalidTime {}
    }
    for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 1, height: CGFloat.nan),
                 CGSize(width: 0.5, height: 1)] {
      do { _ = try await preview.thumbnail(at: .zero, maximumSize: size); XCTFail("invalid size accepted") }
      catch UmbelThumbnailError.invalidMaximumSize {}
    }
    let count = await source.factoryCount
    XCTAssertEqual(count, 0)
  }

  func testRejectsOutOfDurationNoVideoAndSystemOnlyTrack() async throws {
    do { _ = try await generator().thumbnail(at: time(31)); XCTFail("outside duration") }
    catch UmbelThumbnailError.invalidTime {}
    do { _ = try await generator("audio_only.m4a").thumbnail(at: .zero); XCTFail("no video") }
    catch UmbelThumbnailError.noVideo {}
    do { _ = try await generator("dv_p5.mp4").thumbnail(at: .zero); XCTFail("system-only track") }
    catch UmbelThumbnailError.systemDisplayRequired {}
  }

  func testRejectsNonseekableAndCleansUp() async throws {
    let source = ThumbnailStream()
    let preview = UmbelThumbnailGenerator { source }
    do { _ = try await preview.thumbnail(at: .zero); XCTFail("stream cannot seek") }
    catch UmbelThumbnailError.seekUnsupported {}
    let invalidated = await source.invalidated
    XCTAssertTrue(invalidated)
  }

  func testCleansUpAfterSuccessAndOpenFailure() async throws {
    for data in [try Data(contentsOf: fixture("sync_check.mp4")), Data([0, 1, 2])] {
      let source = ThumbnailProbeSource(data: data)
      let preview = UmbelThumbnailGenerator { source }
      _ = try? await preview.thumbnail(at: .zero)
      let invalidated = await source.invalidated
      XCTAssertTrue(invalidated)
    }
  }

  func testCancellationUnblocksReadAndDoesNotCancelQueuedRequest() async throws {
    let blocked = ThumbnailProbeSource(data: Data(), blocking: true)
    let good = ThumbnailProbeSource(data: try Data(contentsOf: fixture("sync_check.mp4")))
    let factory = ThumbnailSourceSequence([blocked, good])
    let preview = UmbelThumbnailGenerator { await factory.next() }
    let first = Task { try await preview.thumbnail(at: .zero) }
    for _ in 0..<200 {
      if await blocked.readStarted { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let started = await blocked.readStarted
    XCTAssertTrue(started)
    let second = Task { try await preview.thumbnail(at: CMTime(value: 1, timescale: 2)) }
    try await Task.sleep(nanoseconds: 20_000_000)
    let callsBefore = await factory.count
    XCTAssertEqual(callsBefore, 1, "a generator opens only one request at once")
    let start = Date()
    first.cancel()
    do { _ = try await first.value; XCTFail("cancelled request returned") }
    catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    let result = try await second.value
    XCTAssertLessThan(try brightness(result.image), 30)
    let closed = await blocked.invalidated
    XCTAssertTrue(closed)
    await blocked.releaseRead()
  }

  func testCancellationDuringDemuxProbeReleasesDetachedRead() async throws {
    let source = ThumbnailProbeSource(
      data: try Data(contentsOf: fixture("sync_check.mp4")), blocking: true, blockAfter: 1)
    let preview = UmbelThumbnailGenerator { source }
    let request = Task { try await preview.thumbnail(at: .zero) }
    for _ in 0..<500 {
      if await source.readCount > 1 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let reads = await source.readCount
    XCTAssertGreaterThan(reads, 1)
    let start = Date()
    request.cancel()
    do { _ = try await request.value; XCTFail("cancelled probe returned") }
    catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    let closed = await source.invalidated
    XCTAssertTrue(closed)
    await source.releaseRead()
  }

  func testCancellingQueuedRequestDoesNotOpenAnotherSource() async throws {
    let source = ThumbnailProbeSource(data: Data(), blocking: true)
    let preview = UmbelThumbnailGenerator { await source.recordFactory(); return source }
    let first = Task { try await preview.thumbnail(at: .zero) }
    for _ in 0..<200 {
      if await source.readStarted { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let queued = Task { try await preview.thumbnail(at: .zero) }
    try await Task.sleep(nanoseconds: 20_000_000)
    queued.cancel()
    do { _ = try await queued.value; XCTFail("cancelled queued request returned") }
    catch is CancellationError {}
    let calls = await source.factoryCount
    XCTAssertEqual(calls, 1)
    first.cancel()
    _ = try? await first.value
    await source.releaseRead()
  }

  func testCancellationDuringFactoryInvalidatesItsLateSource() async throws {
    let source = ThumbnailProbeSource(data: Data())
    let factory = ThumbnailDelayedFactory()
    let preview = UmbelThumbnailGenerator { await factory.open() }
    let request = Task { try await preview.thumbnail(at: .zero) }
    for _ in 0..<200 {
      if await factory.started { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let started = await factory.started
    XCTAssertTrue(started)
    request.cancel()
    do { _ = try await request.value; XCTFail("cancelled factory request returned") }
    catch is CancellationError {}
    await factory.finish(source)
    for _ in 0..<200 {
      if await source.invalidated { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let closed = await source.invalidated
    XCTAssertTrue(closed)
  }

  func testCancellationClosesPlaylistChildSources() async throws {
    let child = ThumbnailProbeSource(data: Data(), blocking: true)
    let root = ThumbnailPlaylistSource(child: child)
    let preview = UmbelThumbnailGenerator { root }
    let request = Task { try await preview.thumbnail(at: .zero) }
    for _ in 0..<500 {
      if await child.readStarted { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    let started = await child.readStarted
    XCTAssertTrue(started)
    request.cancel()
    do { _ = try await request.value; XCTFail("cancelled playlist request returned") }
    catch is CancellationError {}
    let rootClosed = await root.invalidated
    let childClosed = await child.invalidated
    XCTAssertTrue(rootClosed)
    XCTAssertTrue(childClosed)
    await child.releaseRead()
  }

  func testPreviewPreservesActivePlaybackStateAndPosition() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, tolerance: time(0.02))
    let source = try UmbelFileSource(url: fixture("seek_grid.mp4"))
    let session = PlaybackSession(source: source, videoRenderer: renderer, hostTime: ThumbnailHeldTime())
    try await session.load()
    addTeardownBlock { await session.stop(); await source.invalidate() }
    try await session.play()
    var shown = false
    for _ in 0..<200 {
      if try await session.renderVideoFrame() != nil { shown = true; break }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(shown)
    let phase = await session.phase
    let position = await session.currentTime
    let before = try await session.snapshot(includingSubtitles: false)
    _ = try await generator().thumbnail(at: time(10.5))
    let afterPhase = await session.phase
    let afterPosition = await session.currentTime
    let after = try await session.snapshot(includingSubtitles: false)
    XCTAssertEqual(afterPhase, phase)
    XCTAssertEqual(afterPosition, position)
    XCTAssertEqual(before.dataProvider?.data as Data?, after.dataProvider?.data as Data?)
    let sourceBytes = try await source.read(offset: 0, maxLength: 4)
    XCTAssertFalse(sourceBytes.isEmpty)
  }
}

private final class ThumbnailHeldTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

private actor ThumbnailProbeSource: UmbelRandomAccessSource {
  let data: Data
  let blocking: Bool
  let blockAfter: Int
  var readCount = 0
  var invalidated = false
  var readStarted = false
  var factoryCount = 0
  var pending: CheckedContinuation<Data, any Error>?
  init(data: Data, blocking: Bool = false, blockAfter: Int = 0) {
    self.data = data; self.blocking = blocking; self.blockAfter = blockAfter
  }
  var contentLength: Int64? { Int64(data.count) }
  func recordFactory() { factoryCount += 1 }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    readStarted = true
    readCount += 1
    if blocking, readCount > blockAfter {
      return try await withCheckedThrowingContinuation { pending = $0 }
    }
    guard !invalidated else { throw UmbelError.interrupted }
    let start = min(Int(offset), data.count)
    return data.subdata(in: start..<min(start + maxLength, data.count))
  }
  func invalidate() { invalidated = true }
  func releaseRead() { pending?.resume(throwing: UmbelError.interrupted); pending = nil }
}

private actor ThumbnailSourceSequence {
  let sources: [ThumbnailProbeSource]
  var count = 0
  init(_ sources: [ThumbnailProbeSource]) { self.sources = sources }
  func next() -> any UmbelSource { defer { count += 1 }; return sources[count] }
}

private actor ThumbnailStream: UmbelStreamingSource {
  var invalidated = false
  var contentLength: Int64? { nil }
  func readNext(maxLength: Int) async throws -> Data { Data() }
  func invalidate() { invalidated = true }
}

private actor ThumbnailDelayedFactory {
  var started = false
  var pending: CheckedContinuation<any UmbelSource, Never>?
  func open() async -> any UmbelSource {
    started = true
    return await withCheckedContinuation { pending = $0 }
  }
  func finish(_ source: any UmbelSource) { pending?.resume(returning: source); pending = nil }
}

private actor ThumbnailPlaylistSource: UmbelLocatedSource {
  let child: ThumbnailProbeSource
  var invalidated = false
  let data = Data("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
  init(child: ThumbnailProbeSource) { self.child = child }
  var location: URL { URL(fileURLWithPath: "/thumbnail-test/index.m3u8") }
  var contentLength: Int64? { Int64(data.count) }
  func source(for url: URL) -> any UmbelRandomAccessSource { child }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    let start = min(Int(offset), data.count)
    return data.subdata(in: start..<min(start + maxLength, data.count))
  }
  func invalidate() { invalidated = true }
}
