import XCTest
@testable import UmbelCore

private actor BytesSource: UmbelRandomAccessSource {
  let bytes: Data
  let fails: Bool
  init(_ bytes: Data, fails: Bool = false) {
    self.bytes = bytes
    self.fails = fails
  }
  var contentLength: Int64? { Int64(bytes.count) }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    if fails { throw UmbelError.sourceUnavailable(detail: "404") }
    let start = Int(offset)
    guard start < bytes.count else { return Data() }
    return bytes.subdata(in: start..<min(bytes.count, start + maxLength))
  }
  func invalidate() async {}
}

final class HLSSegmentStreamTests: XCTestCase {
  private func segment(_ name: String, run: Int, range: Range<Int64>? = nil) -> HLSMediaPlaylist.Segment {
    HLSMediaPlaylist.Segment(
      url: URL(string: "https://cdn.invalid/\(name)")!, duration: 2, start: 0, run: run, byteRange: range)
  }

  private func makeStream(
    _ segments: [HLSMediaPlaylist.Segment], from index: Int,
    open: @escaping @Sendable (URL) async -> any UmbelRandomAccessSource
  ) -> HLSSegmentStream {
    HLSSegmentStream(
      segments: HLSMediaPlaylist(targetDuration: 2, mediaSequence: 0, segments: segments, isEnded: true),
      startingAt: index, open: open)
  }

  private func readAll(_ stream: HLSSegmentStream) async throws -> String {
    var data = Data()
    while true {
      let next = try await stream.readNext(maxLength: 3)
      if next.isEmpty { return String(decoding: data, as: UTF8.self) }
      data += next
    }
  }

  private func opener(failing: Set<String> = []) -> @Sendable (URL) async -> any UmbelRandomAccessSource {
    let contents: [String: Data] = [
      "a": Data("AAAA".utf8), "b": Data("BB".utf8), "c": Data("CCC".utf8),
    ]
    return { url in
      let name = url.lastPathComponent
      return BytesSource(contents[name] ?? Data(), fails: failing.contains(name))
    }
  }

  func testOneRunsSegmentsInOrderThenTheEnd() async throws {
    let segments = [segment("a", run: 0), segment("b", run: 0), segment("c", run: 1)]
    let stream = makeStream(segments, from: 0, open: opener())
    let read = try await readAll(stream)
    XCTAssertEqual(read, "AAAABB", "not into the next run")
    let next = await stream.nextIndex
    let completed = await stream.completedSegments
    XCTAssertEqual(next, 2)
    XCTAssertEqual(completed, 2)
  }

  func testStartingMidway() async throws {
    let segments = [segment("a", run: 0), segment("b", run: 0)]
    let stream = makeStream(segments, from: 1, open: opener())
    let read = try await readAll(stream)
    XCTAssertEqual(read, "BB")
  }

  func testByteRangesReadOnlyTheirPart() async throws {
    let segments = [segment("a", run: 0, range: 1..<3)]
    let stream = makeStream(segments, from: 0, open: opener())
    let read = try await readAll(stream)
    XCTAssertEqual(read, "AA")
  }

  func testPacketPositionsLocateEarlierSegmentsAfterPrefetchAndSlicing() async throws {
    // Use a nonzero playlist index while logical input still starts at zero.
    let playlist = HLSMediaPlaylist(targetDuration: 2, mediaSequence: 0,
      segments: (0..<4).map { _ in segment("a", run: 1) } + [
        segment("a", run: 0, range: 1..<3), segment("b", run: 0), segment("c", run: 0),
      ], isEnded: true)
    let located = HLSSegmentStream(segments: playlist, startingAt: 4, open: opener())
    let read = try await readAll(located)
    XCTAssertEqual(read, "AABBCCC")
    let first = await located.segment(containing: 0)
    let firstTail = await located.segment(containing: 1)
    let second = await located.segment(containing: 2)
    let third = await located.segment(containing: 4)
    let eof = await located.segment(containing: 7)
    let invalid = await located.segment(containing: -1)
    XCTAssertEqual(first?.index, 4)
    XCTAssertEqual(firstTail?.index, 4)
    XCTAssertEqual(second?.index, 5)
    XCTAssertEqual(third?.index, 6)
    XCTAssertNil(eof)
    XCTAssertNil(invalid)
  }

  func testInitialisationBytesDoNotBelongToAMediaSegment() async throws {
    var first = segment("b", run: 0)
    first.map = .init(url: URL(string: "https://cdn.invalid/a")!, byteRange: 1..<3)
    let stream = makeStream([first, segment("c", run: 0)], from: 0, open: opener())
    let read = try await readAll(stream)
    XCTAssertEqual(read, "AABBCCC")
    let headers = await stream.segment(containing: 1)
    let media = await stream.segment(containing: 2)
    let next = await stream.segment(containing: 4)
    XCTAssertNil(headers)
    XCTAssertEqual(media?.index, 0)
    XCTAssertEqual(next?.index, 1)
  }

  func testEncryptedSegmentsUseDeliveredPlaintextPositions() async throws {
    let directory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls")
    let url = directory.appendingPathComponent("aes/index.m3u8")
    let playlist = try HLSMediaPlaylist.parse(String(contentsOf: url, encoding: .utf8), base: url)
    let server = FixtureServer()
    let stream = HLSSegmentStream(segments: playlist, startingAt: 0, open: { server.source($0) })
    var plain = Data()
    while true {
      let data = try await stream.readNext(maxLength: 4093)
      if data.isEmpty { break }
      plain.append(data)
    }
    let first = try Data(contentsOf: directory.appendingPathComponent("main0"))
    let second = try Data(contentsOf: directory.appendingPathComponent("main1"))
    let third = try Data(contentsOf: directory.appendingPathComponent("main2"))
    let fourth = try Data(contentsOf: directory.appendingPathComponent("main3"))
    XCTAssertEqual(plain, first + second + third + fourth)
    let firstTail = await stream.segment(containing: Int64(first.count - 1))
    let next = await stream.segment(containing: Int64(first.count))
    let thirdHead = await stream.segment(containing: Int64(first.count + second.count))
    XCTAssertEqual(firstTail?.index, 0)
    XCTAssertEqual(next?.index, 1)
    XCTAssertEqual(thirdHead?.index, 2)
  }

  /// A segment that cannot be had ends the run; the caller decides what next.
  func testAFailedSegmentEndsTheRunAndSaysWhich() async throws {
    let segments = [segment("a", run: 0), segment("b", run: 0), segment("c", run: 0)]
    let stream = makeStream(segments, from: 0, open: opener(failing: ["b"]))
    let read = try await readAll(stream)
    XCTAssertEqual(read, "AAAA")
    let failure = await stream.failure
    XCTAssertEqual(failure?.segmentIndex, 1)
  }
}
