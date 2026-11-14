import CoreGraphics
import CoreMedia
import Foundation
import XCTest
@testable import UmbelCore

private actor BlockingSUPSource: UmbelStreamingSource {
  var contentLength: Int64? { get async { nil } }
  private(set) var readStarted = false
  private(set) var invalidated = false
  private var pending: CheckedContinuation<Data, Error>?

  func readNext(maxLength: Int) async throws -> Data {
    readStarted = true
    return try await withCheckedThrowingContinuation { pending = $0 }
  }

  func invalidate() {
    invalidated = true
    pending?.resume(throwing: CancellationError())
    pending = nil
  }
}

final class ExternalSUPTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func testRawSUPKeepsPictureClearEventsAndSeekHistory() async throws {
    let loaded = try await ExternalSubtitleLoader.load(
      UmbelFileSource(url: fixture("external_tiny.sup")),
      id: UmbelTrack.ID(rawValue: 1_000_001), language: "en", title: "External")

    XCTAssertEqual(loaded.track.codecName, "hdmv_pgs_subtitle")
    XCTAssertTrue(loaded.track.isExternal)
    XCTAssertNil(loaded.assScript)
    XCTAssertTrue(loaded.timeline.cues(at: time(1.99)).isEmpty)
    let first = try XCTUnwrap(loaded.timeline.cues(at: time(2.5)).first?.image)
    XCTAssertEqual(first.relativeFrame, CGRect(x: 110.0 / 320, y: 200.0 / 240,
                                                 width: 100.0 / 320, height: 20.0 / 240))
    XCTAssertEqual(first.image.width, 100)
    XCTAssertEqual(first.image.height, 20)
    let pixels = try XCTUnwrap(first.image.dataProvider?.data) as Data
    XCTAssertEqual(Array(pixels.prefix(4)), [255, 255, 255, 255])
    XCTAssertTrue(loaded.timeline.cues(at: time(3.75)).isEmpty)
    let second = try XCTUnwrap(loaded.timeline.cues(at: time(4.25)).first?.image)
    XCTAssertEqual(second.relativeFrame, CGRect(x: 40.0 / 320, y: 20.0 / 240,
                                                  width: 60.0 / 320, height: 30.0 / 240))
    let secondPixels = try XCTUnwrap(second.image.dataProvider?.data) as Data
    XCTAssertEqual(secondPixels[3], 128)
    XCTAssertLessThanOrEqual(secondPixels[2], secondPixels[3])
    XCTAssertTrue(loaded.timeline.cues(at: time(5.25)).isEmpty)
    XCTAssertEqual(loaded.timeline.cues(at: time(2.5)).count, 1)
  }

  func testTruncatedRawSUPIsRejected() async throws {
    var bytes = try Data(contentsOf: fixture("external_tiny.sup"))
    bytes.removeLast()
    do {
      _ = try await ExternalSubtitleLoader.load(
        MemorySource(data: bytes), id: UmbelTrack.ID(rawValue: 1), language: nil, title: nil)
      XCTFail("a truncated segment must not produce a partial external track")
    } catch let error as UmbelError {
      guard case .unsupportedContainer = error else { return XCTFail("\(error)") }
    }
  }

  private func replacingSegments(kind: UInt8, with payload: Data) throws -> Data {
    let original = try Data(contentsOf: fixture("external_tiny.sup"))
    var result = Data()
    var offset = 0
    while offset < original.count {
      let length = Int(original[offset + 11]) * 256 + Int(original[offset + 12])
      let end = offset + 13 + length
      if original[offset + 10] == kind {
        result.append(contentsOf: original[offset..<(offset + 11)])
        result.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        result.append(payload)
      } else {
        result.append(contentsOf: original[offset..<end])
      }
      offset = end
    }
    return result
  }

  func testMalformedPaletteAndWindowPayloadsFailPreflight() throws {
    let malformed: [(UInt8, [UInt8])] = [
      (0x14, []), (0x14, [0]), (0x14, [0, 0, 1, 235]),
      (0x17, []), (0x17, [1]), (0x17, [0, 0]),
    ]
    for (kind, payload) in malformed {
      let bytes = try replacingSegments(kind: kind, with: Data(payload))
      XCTAssertThrowsError(try ExternalSUPInspector.validate(bytes), "segment \(kind), \(payload)")
    }
  }

  func testMalformedWindowsCannotProduceASuccessfulTrack() async throws {
    let bytes = try replacingSegments(kind: 0x17, with: Data())
    do {
      _ = try await ExternalSubtitleLoader.load(
        MemorySource(data: bytes), id: .init(rawValue: 5), language: nil, title: nil)
      XCTFail("a decoder's tolerance must not accept missing window records")
    } catch let error as UmbelError {
      guard case .unsupportedContainer = error else { return XCTFail("\(error)") }
    }
  }

  func testOversizedBitmapIsRejectedBeforeDecode() async throws {
    var bytes = try Data(contentsOf: fixture("external_tiny.sup"))
    // Width and height of the first object in this fixed, generated fixture.
    bytes.replaceSubrange(95..<99, with: [0xFF, 0xFF, 0xFF, 0xFF])
    do {
      _ = try await ExternalSubtitleLoader.load(
        MemorySource(data: bytes), id: UmbelTrack.ID(rawValue: 2), language: nil, title: nil)
      XCTFail("an oversized bitmap must be rejected before the decoder allocates it")
    } catch let error as UmbelError {
      guard case .unsupportedContainer = error else { return XCTFail("\(error)") }
    }
  }

  func testUnreferencedObjectsStillCountAgainstDecoderMemory() throws {
    let original = try Data(contentsOf: fixture("external_tiny.sup"))
    // The first display set ends after its 144-byte ODS segment.
    let object = original.subdata(in: 75..<219)
    var bytes = Data(original.prefix(219))
    for id in 2..<8_500 {
      var segment = object
      segment[13] = UInt8(id >> 8)
      segment[14] = UInt8(id & 0xFF)
      bytes.append(segment)
    }
    bytes.append(contentsOf: original[219..<232])
    XCTAssertThrowsError(try ExternalSUPInspector.validate(bytes))
  }

  func testOversizedCanvasIsRejectedBeforeDecode() throws {
    var bytes = try Data(contentsOf: fixture("external_tiny.sup"))
    bytes[13] = 0xFF
    bytes[14] = 0xFF
    XCTAssertThrowsError(try ExternalSUPInspector.validate(bytes))
  }

  func testCancelledPreflightStopsBeforeDecode() async throws {
    let bytes = try Data(contentsOf: fixture("external_tiny.sup"))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try ExternalSUPInspector.validate(bytes)
    }
    do {
      try await task.value
      XCTFail("preflight ignored task cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testCancellationInterruptsReadAndInvalidatesSource() async throws {
    let source = BlockingSUPSource()
    let task = Task {
      try await ExternalSubtitleLoader.load(
        source, id: UmbelTrack.ID(rawValue: 3), language: nil, title: nil)
    }
    for _ in 0..<100 {
      if await source.readStarted { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let started = await source.readStarted
    XCTAssertTrue(started)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancelled load returned an external track")
    } catch is CancellationError {
      // Expected.
    }
    let invalidated = await source.invalidated
    XCTAssertTrue(invalidated)
  }

  func testAddingRawSUPDoesNotSelectIt() async throws {
    let session = PlaybackSession(source: try UmbelFileSource(url: fixture("styled_subs.mkv")))
    addTeardownBlock { await session.stop() }
    try await session.load()
    let selectedBefore = await session.selectedSubtitleTrack
    let track = try await session.addExternalSubtitle(
      UmbelFileSource(url: fixture("external_tiny.sup")))
    XCTAssertTrue(track.isExternal)
    let selectedAfter = await session.selectedSubtitleTrack
    let tracks = await session.tracks
    XCTAssertEqual(selectedAfter, selectedBefore)
    XCTAssertTrue(tracks.contains(track))
  }

  func testTextVTTStillUsesTextPath() async throws {
    let text = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nExternal VTT\n".utf8)
    let loaded = try await ExternalSubtitleLoader.load(
      MemorySource(data: text), id: UmbelTrack.ID(rawValue: 4),
      language: nil, title: nil)
    XCTAssertEqual(loaded.timeline.cues(at: time(1.5)).map(\.plainText), ["External VTT"])
    XCTAssertTrue(loaded.timeline.cues(at: time(2.5)).isEmpty)
  }
}
