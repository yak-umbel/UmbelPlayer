import XCTest
@testable import UmbelFFmpegSupport

private actor ByteReader {
  private let data: Data
  private var position = 0
  let length: Int64?

  init(data: Data) {
    self.data = data
    self.length = Int64(data.count)
  }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }
}

private func openDemuxer(named name: String) throws -> FFmpegDemuxer {
  let data = try Data(contentsOf: FixtureLocator.url(for: name))
  let reader = ByteReader(data: data)
  let callbacks = FFmpegIOCallbacks(
    read: { maxLength in await reader.read(maxLength: maxLength) },
    seek: { offset in await reader.seek(to: offset) },
    totalLength: { await reader.length },
    canSeek: true
  )
  return FFmpegDemuxer(callbacks: callbacks, configuration: .init())
}

final class FFmpegAudioDecoderTests: XCTestCase {
  func testDecodesAacToPlanarFloat() async throws {
    let demuxer = try openDemuxer(named: "audio_only.m4a")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let audio = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    let decoder = try await demuxer.makeAudioDecoder(streamIndex: audio.index)
    defer { decoder.close() }

    XCTAssertEqual(decoder.sampleRate, 48_000)
    XCTAssertEqual(decoder.channelCount, 2)

    var totalFrames = 0
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == audio.index else { continue }
      for frame in try decoder.decode(packet) {
        XCTAssertEqual(frame.channelCount, 2)
        XCTAssertEqual(frame.sampleRate, 48_000)
        XCTAssertEqual(frame.samples.count, frame.frameCount * frame.channelCount,
                       "planar, the total is samples per channel times channels")
        totalFrames += frame.frameCount
      }
    }

    // 2 seconds × 48000 Hz, allowing for the encoder's padding.
    XCTAssertGreaterThan(totalFrames, 80_000)
    XCTAssertLessThan(totalFrames, 110_000)
  }

  func testDecodedSamplesAreNotAllSilent() async throws {
    let demuxer = try openDemuxer(named: "audio_only.m4a")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let audio = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    let decoder = try await demuxer.makeAudioDecoder(streamIndex: audio.index)
    defer { decoder.close() }

    var peak: Float = 0
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == audio.index else { continue }
      for frame in try decoder.decode(packet) {
        for sample in frame.samples { peak = max(peak, abs(sample)) }
      }
    }

    // The fixture's true peak, measured with ffmpeg's volumedetect, is
    // -20.8 dB, a linear amplitude of about 0.091 (the sine filter that made
    // it is not at full scale). A range rather than one bound: it catches
    // silence (0), and resampling errors that halve (≈0.046) or double
    // (≈0.18) the amplitude. Should a regenerated fixture fail here, measure
    // the true value with volumedetect before changing it; do not just widen
    // the range.
    XCTAssertGreaterThan(peak, 0.05, "what decodes is not silence")
    XCTAssertLessThan(peak, 0.15, "the amplitude is well off the level of the fixture; resampling may be wrong")
  }

  func testTimestampsAdvanceMonotonically() async throws {
    let demuxer = try openDemuxer(named: "audio_only.m4a")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let audio = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    let decoder = try await demuxer.makeAudioDecoder(streamIndex: audio.index)
    defer { decoder.close() }

    var previous = Int64.min
    var checked = 0
    while let packet = try await demuxer.readPacket(), checked < 20 {
      guard packet.streamIndex == audio.index else { continue }
      for frame in try decoder.decode(packet) {
        guard frame.pts != FFmpegPacket.noTimestamp else { continue }
        XCTAssertGreaterThan(frame.pts, previous)
        previous = frame.pts
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 0)
  }

  /// Opus starts with 312 samples of decoder delay (6.5 ms at 48 kHz), dropped
  /// by the decoder from the first frame; the packet itself is stamped 6.5 ms
  /// before zero. The frame is then stamped where its first kept sample is:
  /// given the packets' time base, FFmpeg moves the stamp on by what it
  /// dropped. Where a codec packs several blocks to a packet the delay is
  /// dropped from inside one, and the stamp that was left would be tens of
  /// milliseconds early.
  func testSamplesDroppedFromTheFirstFrameMoveItsStamp() async throws {
    let demuxer = try openDemuxer(named: "opus_pre_skip.ogg")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let audio = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    let decoder = try await demuxer.makeAudioDecoder(streamIndex: audio.index)
    defer { decoder.close() }

    var first: FFmpegAudioFrame?
    while first == nil, let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == audio.index else { continue }
      first = try decoder.decode(packet).first
    }
    let frame = try XCTUnwrap(first)
    XCTAssertEqual(frame.frameCount, 960 - 312, "the delay was dropped from the first frame")
    let seconds = Double(frame.pts) * Double(frame.timeBaseNum) / Double(frame.timeBaseDen)
    XCTAssertEqual(seconds, 0, accuracy: 0.0002)
  }

  func testDecodesAc3FromMultiTrackFixture() async throws {
    let demuxer = try openDemuxer(named: "multi_track.mkv")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let ac3 = try XCTUnwrap(streams.first { $0.codecName == "ac3" })
    let decoder = try await demuxer.makeAudioDecoder(streamIndex: ac3.index)
    defer { decoder.close() }

    var produced = 0
    while let packet = try await demuxer.readPacket(), produced == 0 {
      guard packet.streamIndex == ac3.index else { continue }
      produced += try decoder.decode(packet).count
    }
    XCTAssertGreaterThan(produced, 0, "an AC-3 track decodes too")
  }

  func testMakingDecoderForVideoStreamThrows() async throws {
    let demuxer = try openDemuxer(named: "multi_track.mkv")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    do {
      _ = try await demuxer.makeAudioDecoder(streamIndex: video.index)
      XCTFail("making an audio decoder for a video stream throws")
    } catch {
      // As expected
    }
  }

  func testCloseIsIdempotent() async throws {
    let demuxer = try openDemuxer(named: "audio_only.m4a")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let audio = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    let decoder = try await demuxer.makeAudioDecoder(streamIndex: audio.index)
    decoder.close()
    decoder.close()
  }
}
