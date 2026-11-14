import XCTest
@testable import UmbelFFmpegSupport

/// A whole fixture in memory, for the demuxer to read.
private actor MemoryReader {
  private let data: Data
  private var position = 0
  init(_ data: Data) { self.data = data }
  func read(maxLength: Int) -> Data {
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }
  func seek(to offset: Int64) { position = min(Int(offset), data.count) }
  var length: Int64 { Int64(data.count) }
}

final class FFmpegInitSegmentTests: XCTestCase {
  /// eac3_movie.mkv: its Matroska track carries no stream description; the
  /// MP4 one is made from the frames.
  func testTheMovieBoxDescribesEAC3FromItsFrames() async throws {
    let reader = MemoryReader(try Data(contentsOf: FixtureLocator.url(for: "eac3_movie.mkv")))
    let demuxer = FFmpegDemuxer(
      callbacks: FFmpegIOCallbacks(
        read: { await reader.read(maxLength: $0) }, seek: { await reader.seek(to: $0) },
        totalLength: { await reader.length }, canSeek: true),
      configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let sound = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    var packets: [FFmpegPacket] = []
    while packets.count < 4, let packet = try await demuxer.readPacket() {
      if packet.streamIndex == sound.index { packets.append(packet) }
    }
    let found = await demuxer.codecParameters(streamIndex: sound.index)
    let parameters = try XCTUnwrap(found)

    let segment = try FFmpegInitSegment.make(parameters: parameters, packets: packets)
    XCTAssertEqual(String(decoding: segment[4..<8], as: UTF8.self), "ftyp")
    XCTAssertNotNil(segment.range(of: Data("moov".utf8)))
    XCTAssertNotNil(segment.range(of: Data("dec3".utf8)), "described from the frames")
    XCTAssertNil(segment.range(of: Data("moof".utf8)), "the fragments it wrote are left out")
  }
}
