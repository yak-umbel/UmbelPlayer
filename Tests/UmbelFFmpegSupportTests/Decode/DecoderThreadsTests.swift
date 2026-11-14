import VideoToolbox
import XCTest
@testable import UmbelFFmpegSupport

private actor ThreadsFixtureBytes {
  private let data: Data
  private var position = 0
  let length: Int64

  init(named name: String) throws {
    data = try Data(contentsOf: FixtureLocator.url(for: name))
    length = Int64(data.count)
  }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }
}

/// How many threads software decoding runs on, and what a decoder keeps of
/// what it was asked.
final class DecoderThreadsTests: XCTestCase {
  private func open(_ name: String) async throws -> (FFmpegDemuxer, FFmpegStreamInfo) {
    let bytes = try ThreadsFixtureBytes(named: name)
    let demuxer = FFmpegDemuxer(callbacks: FFmpegIOCallbacks(
      read: { await bytes.read(maxLength: $0) }, seek: { await bytes.seek(to: $0) },
      totalLength: { bytes.length }, canSeek: true), configuration: .init())
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    return (demuxer, try XCTUnwrap(streams.first { $0.mediaType == .video }))
  }

  func testSoftwareDecodingRunsOnTheThreadsAskedFor() async throws {
    let (demuxer, video) = try await open("moov_at_end.mp4")
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false, softwareThreadCount: 4)
    defer { decoder.close() }
    XCTAssertFalse(decoder.isHardwareAccelerated)
    XCTAssertEqual(decoder.threadCount, 4)
  }

  func testAnAV1StreamInSoftwareRunsOnTheThreadsAskedFor() async throws {
    let (demuxer, video) = try await open("av1_8bit.mp4")
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false, softwareThreadCount: 2)
    defer { decoder.close() }
    XCTAssertFalse(decoder.isHardwareAccelerated)
    XCTAssertEqual(decoder.threadCount, 2, "libdav1d is given the count as FFmpeg's other decoders are")
  }

  /// What it did before the count could be asked for: FFmpeg's own pick.
  func testNotAskingLeavesTheThreadsToFFmpeg() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 2, "one core is one thread")
    let (demuxer, video) = try await open("moov_at_end.mp4")
    let decoder = try await demuxer.makeVideoDecoder(streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }
    XCTAssertGreaterThan(decoder.threadCount, 1)
    XCTAssertLessThanOrEqual(decoder.threadCount, 16, "FFmpeg's own limit")
    XCTAssertEqual(decoder.requestedSoftwareThreads, 0)
  }

  func testHardwareDecodingIgnoresTheThreadCount() async throws {
    try XCTSkipUnless(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "no hardware H.264")
    let (demuxer, video) = try await open("moov_at_end.mp4")
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: true, softwareThreadCount: 4)
    defer { decoder.close() }
    XCTAssertTrue(decoder.isHardwareAccelerated)
    XCTAssertEqual(decoder.threadCount, 1, "each extra frame thread would hold more surfaces")
  }

  /// A decoder made again, as after the app was in the background, is asked
  /// the same; so it has to know what it was asked.
  func testADecoderKnowsWhatItWasAskedFor() async throws {
    let (demuxer, video) = try await open("moov_at_end.mp4")
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false, softwareThreadCount: 4)
    defer { decoder.close() }
    XCTAssertFalse(decoder.prefersHardware)
    XCTAssertEqual(decoder.requestedSoftwareThreads, 4)

    let parameters = try XCTUnwrap(decoder.parameters)
    let again = try parameters.makeVideoDecoder(
      preferHardware: decoder.prefersHardware, softwareThreadCount: decoder.requestedSoftwareThreads)
    defer { again.close() }
    XCTAssertEqual(again.threadCount, 4)
  }

  // ── Hardware that refuses the stream once it has seen it ──

  /// The pictures and times a decoder gives for a whole file.
  private func decodeAll(
    _ name: String, preferHardware: Bool
  ) async throws -> (decoder: FFmpegVideoDecoder, frames: [FFmpegVideoFrame]) {
    let (demuxer, video) = try await open(name)
    let decoder = try await demuxer.makeVideoDecoder(streamIndex: video.index, preferHardware: preferHardware)
    addTeardownBlock { decoder.close() }
    var frames: [FFmpegVideoFrame] = []
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == video.index else { continue }
      frames += try decoder.decode(packet)
    }
    frames += try decoder.decode(FFmpegPacket(
      streamIndex: video.index, data: Data(), pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
      duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false))
    return (decoder, frames)
  }

  /// A 16 × 16 H.264 stream passes the check made before hardware is tried,
  /// and VideoToolbox then refuses it with the first picture: FFmpeg goes on
  /// in software, on the single thread the decoder was opened with for
  /// hardware. It has to be told apart from hardware decoding, and made again
  /// as a software decoder is.
  func testHardwareThatRefusesTheStreamLeavesASoftwareDecoderOnItsThreads() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 2, "one core is one thread")
    let (decoder, frames) = try await decodeAll("h264_16x16.mp4", preferHardware: true)
    try XCTSkipIf(frames.contains { $0.wasHardwareDecoded }, "this hardware decodes the stream")
    XCTAssertFalse(decoder.isHardwareAccelerated, "it does not decode in hardware, whatever it was made to try")
    XCTAssertGreaterThan(decoder.threadCount, 1)
    XCTAssertTrue(decoder.prefersHardware, "and it is asked the same if made again")
  }

  /// The decoder made again for the picture the first one refused, which is
  /// the one picture of the stream so far: nothing is lost or given twice.
  func testTheSwitchLosesAndRepeatsNoPicture() async throws {
    let (_, tried) = try await decodeAll("h264_16x16.mp4", preferHardware: true)
    try XCTSkipIf(tried.contains { $0.wasHardwareDecoded }, "this hardware decodes the stream")
    let (_, software) = try await decodeAll("h264_16x16.mp4", preferHardware: false)
    XCTAssertFalse(software.isEmpty)
    XCTAssertEqual(tried.map(\.pts), software.map(\.pts))
    XCTAssertTrue(tried.allSatisfy { !$0.wasHardwareDecoded })
  }

  /// The hardware, where it accepts a stream, is not given up for software.
  func testHardwareThatAcceptsTheStreamIsKept() async throws {
    try XCTSkipUnless(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264), "no hardware H.264")
    let (decoder, frames) = try await decodeAll("moov_at_end.mp4", preferHardware: true)
    XCTAssertTrue(decoder.isHardwareAccelerated)
    XCTAssertFalse(frames.isEmpty)
    XCTAssertTrue(frames.allSatisfy(\.wasHardwareDecoded))
    XCTAssertEqual(decoder.threadCount, 1)
  }
}
