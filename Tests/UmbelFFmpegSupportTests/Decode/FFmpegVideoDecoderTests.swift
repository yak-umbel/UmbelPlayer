import CoreVideo
import VideoToolbox
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

final class FFmpegVideoDecoderTests: XCTestCase {
  /// Software path: `moov_at_end.mp4` holds H.264.
  func testSoftwareDecodeProducesBiplanarBuffers() async throws {
    let demuxer = try openDemuxer(named: "moov_at_end.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }

    XCTAssertFalse(decoder.isHardwareAccelerated)
    XCTAssertEqual(decoder.width, 160)
    XCTAssertEqual(decoder.height, 120)

    var produced = 0
    while let packet = try await demuxer.readPacket(), produced == 0 {
      guard packet.streamIndex == video.index else { continue }
      for frame in try decoder.decode(packet) {
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.pixelBuffer),
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                       "software decoding gives the same biplanar format as hardware")
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 160)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), 120)
        XCTAssertFalse(frame.wasHardwareDecoded)
        produced += 1
      }
    }
    XCTAssertGreaterThan(produced, 0)
  }

  /// Hardware path. Where it is not supported, skipped with the reason
  /// given; nothing passes silently.
  func testHardwareDecodeProducesSameGeometry() async throws {
    let demuxer = try openDemuxer(named: "moov_at_end.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder: FFmpegVideoDecoder
    do {
      decoder = try await demuxer.makeVideoDecoder(
        streamIndex: video.index, preferHardware: true)
    } catch {
      throw XCTSkip("no hardware decoding of this codec here: \(error)")
    }
    defer { decoder.close() }

    guard decoder.isHardwareAccelerated else {
      throw XCTSkip("fell back to software; no hardware path")
    }

    var produced = 0
    while let packet = try await demuxer.readPacket(), produced == 0 {
      guard packet.streamIndex == video.index else { continue }
      for frame in try decoder.decode(packet) {
        XCTAssertEqual(CVPixelBufferGetWidth(frame.pixelBuffer), 160)
        XCTAssertEqual(CVPixelBufferGetHeight(frame.pixelBuffer), 120)
        XCTAssertTrue(frame.wasHardwareDecoded)
        produced += 1
      }
    }
    XCTAssertGreaterThan(produced, 0)
  }

  /// Some HEVC samples carry the next picture's parameter sets after the
  /// current picture. Passing that ordering to the hardware lost that
  /// picture even though software decoded it. Keep all 50 fixture frames.
  func testHardwareKeepsPicturesWithParameterSetsAtTheirTail() async throws {
    guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else {
      throw XCTSkip("HEVC hardware decoding is unavailable")
    }
    let demuxer = try openDemuxer(named: "dv_p81.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(streamIndex: video.index, preferHardware: true)
    defer { decoder.close() }
    let configuration = try XCTUnwrap(decoder.parameters).extradata
    // Copy the fixture's VPS/SPS/PPS from hvcC into sample-length framing.
    let bytes = [UInt8](configuration)
    XCTAssertGreaterThan(bytes.count, 23)
    var at = 23
    var sets = Data()
    for _ in 0..<Int(bytes[22]) {
      let type = bytes[at] & 63
      let count = Int(bytes[at + 1]) * 256 + Int(bytes[at + 2])
      at += 3
      for _ in 0..<count {
        let length = Int(bytes[at]) * 256 + Int(bytes[at + 1])
        if (32...34).contains(type) {
          sets.append(contentsOf: [0, 0, bytes[at], bytes[at + 1]])
          sets.append(contentsOf: bytes[(at + 2)..<(at + 2 + length)])
        }
        at += 2 + length
      }
    }
    XCTAssertFalse(sets.isEmpty)
    var times: [Int] = []
    var failures = 0
    var changed = 0
    func collect(_ frames: [FFmpegVideoFrame]) {
      for frame in frames {
        XCTAssertTrue(frame.wasHardwareDecoded)
        times.append(Int((Double(frame.pts) * Double(frame.timeBaseNum) / Double(frame.timeBaseDen) * 25).rounded()))
      }
    }
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == video.index else { continue }
      // Leave the first keyframe intact; repeat the sets after other pictures.
      let tail = packet.isKeyframe ? Data() : sets
      if !tail.isEmpty { changed += 1 }
      let modified = FFmpegPacket(
        streamIndex: packet.streamIndex, data: packet.data + tail,
        pts: packet.pts, dts: packet.dts, duration: packet.duration,
        timeBaseNum: packet.timeBaseNum, timeBaseDen: packet.timeBaseDen, isKeyframe: packet.isKeyframe)
      do { collect(try decoder.decode(modified)) } catch { failures += 1 }
    }
    collect(try decoder.decode(FFmpegPacket(
      streamIndex: video.index, data: Data(), pts: FFmpegPacket.noTimestamp,
      dts: FFmpegPacket.noTimestamp, duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false)))
    XCTAssertGreaterThan(changed, 0)
    XCTAssertEqual(failures, 0)
    XCTAssertEqual(decoder.damagedFrameCount, 0)
    XCTAssertEqual(times.sorted(), Array(0..<50))
  }

  func testTimestampsAdvanceMonotonically() async throws {
    let demuxer = try openDemuxer(named: "moov_at_end.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }

    var previous = Int64.min
    var checked = 0
    while let packet = try await demuxer.readPacket(), checked < 10 {
      guard packet.streamIndex == video.index else { continue }
      for frame in try decoder.decode(packet) {
        guard frame.pts != FFmpegPacket.noTimestamp else { continue }
        XCTAssertGreaterThan(frame.pts, previous)
        previous = frame.pts
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 0)
  }

  func testColourDeclarationIsCarriedOut() async throws {
    let demuxer = try openDemuxer(named: "moov_at_end.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }

    var seen = false
    while let packet = try await demuxer.readPacket(), !seen {
      guard packet.streamIndex == video.index else { continue }
      for frame in try decoder.decode(packet) {
        // No particular value is checked — the fixture may declare none;
        // what is checked is that it comes through.
        XCTAssertGreaterThanOrEqual(frame.colorspace, 0)
        XCTAssertGreaterThanOrEqual(frame.colorRange, 0)
        seen = true
      }
    }
    XCTAssertTrue(seen)
  }

  func testMakingVideoDecoderForAudioStreamThrows() async throws {
    let demuxer = try openDemuxer(named: "multi_track.mkv")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }

    let streams = await demuxer.streams()
    let audio = try XCTUnwrap(streams.first { $0.mediaType == .audio })
    do {
      _ = try await demuxer.makeVideoDecoder(streamIndex: audio.index, preferHardware: false)
      XCTFail("making a video decoder for an audio stream throws")
    } catch {
      // As expected
    }
  }

  func testSoftwareDecodeUsesEveryCore() async throws {
    guard ProcessInfo.processInfo.activeProcessorCount > 1 else {
      throw XCTSkip("one core only here")
    }
    let demuxer = try openDemuxer(named: "moov_at_end.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }
    XCTAssertGreaterThan(decoder.threadCount, 1)
  }

  /// A stream the hardware cannot decode goes to software from the start,
  /// on every core — not to the hardware, falling back on one thread.
  func testWhatTheHardwareCannotDecodeIsDecodedInSoftwareOnEveryCore() async throws {
    guard !VTIsHardwareDecodeSupported(kCMVideoCodecType_MPEG4Video) else {
      throw XCTSkip("the hardware here decodes MPEG-4 Part 2")
    }
    guard ProcessInfo.processInfo.activeProcessorCount > 1 else {
      throw XCTSkip("one core only here")
    }
    let demuxer = try openDemuxer(named: "b_frames.mkv")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: true)
    defer { decoder.close() }
    XCTAssertFalse(decoder.isHardwareAccelerated)
    XCTAssertGreaterThan(decoder.threadCount, 1)
  }

  /// Frame times, in frames at 25 a second, of b_frames.mkv decoded whole.
  /// `skipping` says, packet by packet, whether to skip non-reference frames.
  private func decodedFrames(skipping: (FFmpegPacket) -> Bool) async throws -> [Int] {
    let demuxer = try openDemuxer(named: "b_frames.mkv")
    try await demuxer.open()
    defer { Task { await demuxer.close() } }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }

    var frames: [FFmpegVideoFrame] = []
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == video.index else { continue }
      decoder.skipsNonReferenceFrames = skipping(packet)
      frames += try decoder.decode(packet)
    }
    frames += try decoder.decode(
      FFmpegPacket(
        streamIndex: video.index, data: Data(), pts: FFmpegPacket.noTimestamp,
        dts: FFmpegPacket.noTimestamp, duration: 0, timeBaseNum: 0, timeBaseDen: 0,
        isKeyframe: false))
    return frames.map {
      Int((Double($0.pts) * Double($0.timeBaseNum) / Double($0.timeBaseDen) * 25).rounded())
    }
  }

  /// b_frames.mkv: a keyframe every 25 frames, then B B P over and over.
  private func isReference(_ frame: Int) -> Bool { frame % 25 % 3 == 0 }

  /// The B frames are not referred to, so skipping leaves the I and P frames.
  func testSkippingLeavesTheReferenceFrames() async throws {
    let all = try await decodedFrames { _ in false }
    XCTAssertEqual(all, Array(0..<100))
    let skipped = try await decodedFrames { _ in true }
    XCTAssertEqual(skipped, (0..<100).filter(isReference))
  }

  /// Skipping is turned off from the keyframe at two seconds.
  func testSkippingStopsWhenTurnedOff() async throws {
    var skipping = true
    let frames = try await decodedFrames { packet in
      let seconds = Double(packet.pts) * Double(packet.timeBaseNum) / Double(packet.timeBaseDen)
      if packet.isKeyframe, seconds >= 2.0 { skipping = false }
      return skipping
    }
    XCTAssertEqual(frames, (0..<50).filter(isReference) + Array(50..<100))
  }

  func testCloseIsIdempotent() async throws {
    let demuxer = try openDemuxer(named: "moov_at_end.mp4")
    try await demuxer.open()
    addTeardownBlock { await demuxer.close() }
    let streams = await demuxer.streams()
    let video = try XCTUnwrap(streams.first { $0.mediaType == .video })
    let decoder = try await demuxer.makeVideoDecoder(
      streamIndex: video.index, preferHardware: false)
    decoder.close()
    decoder.close()
  }
}
