import XCTest
@testable import UmbelFFmpegSupport

/// A file served from memory, and able to be cut: with `failAt`, a read that
/// reaches that offset throws — a connection that dropped midway.
private actor CutReader {
  struct Cut: Error, Equatable {}

  private let data: Data
  private var position = 0
  private var failAt: Int?

  init(_ data: Data) { self.data = data }

  func failFrom(_ offset: Int?) { failAt = offset }

  func read(maxLength: Int) throws -> Data {
    if let failAt, position >= failAt { throw Cut() }
    guard position < data.count else { return Data() }
    let stop = min(failAt ?? data.count, data.count)
    let end = min(position + maxLength, stop)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }

  var length: Int64 { Int64(data.count) }
}

/// The whole of a small file would be read before `open` returns; a small
/// probe leaves the end to be reached by reading packets, as in a long file.
private let smallProbe = FFmpegDemuxerConfiguration(
  ioBufferSize: 4096, probeSize: 8192, analyzeDurationMicroseconds: 100_000)
private let configurations: [(name: String, configuration: FFmpegDemuxerConfiguration)] = [
  ("default probe", .init()), ("small probe", smallProbe),
]

private func demuxer(
  over data: Data, reader: CutReader? = nil, configuration: FFmpegDemuxerConfiguration = .init()
) -> FFmpegDemuxer {
  let reader = reader ?? CutReader(data)
  return FFmpegDemuxer(
    callbacks: FFmpegIOCallbacks(
      read: { maxLength in try await reader.read(maxLength: maxLength) },
      seek: { offset in await reader.seek(to: offset) },
      totalLength: { await reader.length },
      canSeek: true),
    configuration: configuration)
}

/// An audio file, several packets to a PES. Its PESs declare their length,
/// which is what lets the demuxer tell one that was cut short.
private func audioFile() throws -> Data {
  try Data(contentsOf: FixtureLocator.url(for: "rate_change.ts"))
}

/// Every packet up to the end, as the demuxer hands them over.
private func drain(_ demuxer: FFmpegDemuxer) async throws -> [FFmpegPacket] {
  var packets: [FFmpegPacket] = []
  while let packet = try await demuxer.readPacket() { packets.append(packet) }
  return packets
}

private func packets(of data: Data, configuration: FFmpegDemuxerConfiguration) async throws -> [FFmpegPacket] {
  let demuxer = demuxer(over: data, configuration: configuration)
  try await demuxer.open()
  do {
    let all = try await drain(demuxer)
    await demuxer.close()
    return all
  } catch {
    await demuxer.close()
    throw error
  }
}

/// Where each PES of a whole file begins: the index of its first packet, and
/// the offset in the file. Only a PES's first packet knows its position.
private func pesStarts(_ whole: [FFmpegPacket]) -> [(index: Int, offset: Int)] {
  whole.enumerated().compactMap { index, packet in packet.bytePosition.map { (index, Int($0)) } }
}

/// What came out of a cut file is the start of what the whole file gives:
/// the packets before the last are the same, and the last is the same or a
/// piece of its start.
private func assertIsTheStartOf(
  _ delivered: [FFmpegPacket], _ whole: [FFmpegPacket], _ label: String,
  file: StaticString = #filePath, line: UInt = #line
) {
  guard delivered.count <= whole.count else {
    return XCTFail("\(label): \(delivered.count) packets out of \(whole.count)", file: file, line: line)
  }
  for (index, packet) in delivered.enumerated() {
    let expected = whole[index]
    XCTAssertEqual(packet.pts, expected.pts, "\(label) #\(index) time", file: file, line: line)
    if index < delivered.count - 1 {
      XCTAssertEqual(packet.data, expected.data, "\(label) #\(index) bytes", file: file, line: line)
    } else {
      XCTAssertTrue(
        expected.data.starts(with: packet.data), "\(label) #\(index) is not a start of the whole one",
        file: file, line: line)
    }
  }
}

/// A file that ends in the middle of a packet has a short last packet: what
/// is there is what the file has, and it is handed over. A read that fails
/// midway is another matter — the packet it cut short is not the file's, and
/// a decoder given it would report a decoding error for what is a network
/// error.
final class FFmpegTruncatedTailTests: XCTestCase {
  func testAFileCutInsideAPESGivesTheWholePacketsOfItThatAreThere() async throws {
    let data = try audioFile()
    for (name, configuration) in configurations {
      let whole = try await packets(of: data, configuration: configuration)
      XCTAssertEqual(whole.count, 183, name)
      let starts = pesStarts(whole)
      for start in [starts[starts.count / 2], starts[starts.count - 1]] {
        let delivered = try await packets(
          of: Data(data.prefix(start.offset + 188 * 3)), configuration: configuration)
        let label = "\(name), cut inside the PES at \(start.offset)"
        XCTAssertGreaterThan(delivered.count, start.index, "\(label): some of it arrives")
        assertIsTheStartOf(delivered, whole, label)
      }
    }
  }

  func testAReadThatFailsMidwayDoesNotHandOnTheCutPES() async throws {
    let data = try audioFile()
    let whole = try await packets(of: data, configuration: smallProbe)
    let starts = pesStarts(whole)
    let cut = starts[starts.count / 2]
    let reader = CutReader(data)
    let demuxer = demuxer(over: data, reader: reader, configuration: smallProbe)
    try await demuxer.open()
    await reader.failFrom(cut.offset + 188 * 3)

    var delivered: [FFmpegPacket] = []
    do {
      while let packet = try await demuxer.readPacket() { delivered.append(packet) }
      XCTFail("a cut connection is no end of file")
    } catch let error as CutReader.Cut {
      XCTAssertEqual(error, CutReader.Cut())
    }
    XCTAssertFalse(delivered.isEmpty)
    XCTAssertLessThanOrEqual(delivered.count, cut.index, "nothing of the PES the read cut short")
    assertIsTheStartOf(delivered, whole, "before the cut")
    await demuxer.close()
  }

  /// Having come to the end once, a read that fails after a seek back is
  /// still no end of file.
  func testACutPESIsStillDroppedAfterSeekingBackFromTheEnd() async throws {
    let data = try audioFile()
    let whole = try await packets(of: data, configuration: smallProbe)
    let starts = pesStarts(whole)
    let cut = starts[starts.count / 2]
    let reader = CutReader(data)
    let demuxer = demuxer(over: data, reader: reader, configuration: smallProbe)
    try await demuxer.open()
    _ = try await drain(demuxer)
    await reader.failFrom(cut.offset + 188 * 3)
    try await demuxer.seek(toSeconds: 0)

    var delivered: [FFmpegPacket] = []
    do {
      while let packet = try await demuxer.readPacket() { delivered.append(packet) }
      XCTFail("a cut connection is no end of file")
    } catch is CutReader.Cut {}
    XCTAssertFalse(delivered.isEmpty)
    XCTAssertLessThanOrEqual(delivered.count, cut.index, "nothing of the PES the read cut short")
    await demuxer.close()
  }
}
