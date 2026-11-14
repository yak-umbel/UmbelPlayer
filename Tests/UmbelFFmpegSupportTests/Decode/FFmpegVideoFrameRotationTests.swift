import XCTest
@testable import UmbelFFmpegSupport

private actor ByteReader {
  private let data: Data
  private var position = 0

  init(data: Data) { self.data = data }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }

  var length: Int64 { Int64(data.count) }
}

/// A decoded frame carries the rotation its stream declared, read from the
/// same codec parameters the stream's description is: the two cannot differ.
final class FFmpegVideoFrameRotationTests: XCTestCase {
  /// The first frame, and whether hardware decoded the stream.
  private func firstFrame(
    of name: String, preferHardware: Bool = false
  ) async throws -> (frame: FFmpegVideoFrame, hardware: Bool) {
    let data = try Data(contentsOf: FixtureLocator.url(for: name))
    let reader = ByteReader(data: data)
    let demuxer = FFmpegDemuxer(
      callbacks: FFmpegIOCallbacks(
        read: { maxLength in await reader.read(maxLength: maxLength) },
        seek: { offset in await reader.seek(to: offset) },
        totalLength: { await reader.length },
        canSeek: true),
      configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video }, name)
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: preferHardware)
    defer { decoder.close() }

    var frames: [FFmpegVideoFrame] = []
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == video.index else { continue }
      frames += try decoder.decode(packet)
    }
    // An empty packet drains what the decoder still holds.
    frames += try decoder.decode(FFmpegPacket(
      streamIndex: 0, data: Data(),
      pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
      duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false))
    return (try XCTUnwrap(frames.first, name), decoder.isHardwareAccelerated)
  }

  func testFramesCarryTheirStreamsRotation() async throws {
    let declared: [(name: String, degrees: Int32)] = [
      ("rotation_none.mp4", 0), ("rotation_cw90.mp4", 90), ("rotation_cw180.mp4", 180),
      ("rotation_cw270.mp4", 270), ("rotation_flipped.mp4", 0),
    ]
    for (name, degrees) in declared {
      let frame = try await firstFrame(of: name).frame
      XCTAssertEqual(frame.rotation, degrees, name)
      XCTAssertEqual(frame.width, 128, "the stored size does not change with the turn")
      XCTAssertEqual(frame.height, 64, "the stored size does not change with the turn")
    }
  }

  /// Hardware decoding hands its frames over through the same conversion;
  /// skipped where the system does not decode this stream here.
  func testHardwareDecodedFramesCarryItToo() async throws {
    let (frame, hardware) = try await firstFrame(of: "rotation_cw90.mp4", preferHardware: true)
    guard hardware else { throw XCTSkip("no hardware decoding of this stream here") }
    XCTAssertTrue(frame.wasHardwareDecoded)
    XCTAssertEqual(frame.rotation, 90)
  }
}
