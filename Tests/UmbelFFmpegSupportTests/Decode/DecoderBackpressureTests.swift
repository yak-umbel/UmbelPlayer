import FFmpeg
import XCTest
@testable import UmbelFFmpegSupport

/// Real software decoding with occupied output and input buffers. Only the
/// setup bypasses the wrapper; EAGAIN comes from the actual codec.
final class DecoderBackpressureTests: XCTestCase {
  func testVideoRecoversFromFullBuffersWithoutLosingPackets() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(2)))
    decoder.operations.send = backlog.send

    var times: [Int64] = []
    var failures: [String] = []
    for packet in fixture.packets.dropFirst(2) + [DecodeInput.drain] {
      do { times += try decoder.decode(packet).map(\.pts) }
      catch { failures.append(String(describing: error)) }
    }
    XCTAssertTrue(backlog.sawBackpressure, "setup must reach real codec backpressure")
    XCTAssertEqual(failures.count, 0, "repeated failures: \(failures.prefix(4))")
    XCTAssertEqual(times, fixture.packets.map(\.pts), "all 50 frames, without a seek or flush")
    XCTAssertEqual(decoder.damagedFrameCount, 0, "backpressure is not damaged input")
  }

  func testAudioRecoversFromFullBuffersWithoutLosingPackets() async throws {
    let fixture = try await DecodeInput.load("audio_only.m4a", mediaType: .audio)
    let decoder = try fixture.parameters.makeAudioDecoder()
    defer { decoder.close() }
    // The first AAC packet is encoder priming and produces no frame.
    let backlog = PendingPackets(Array(fixture.packets.prefix(3)))
    decoder.operations.send = backlog.send

    var times: [Int64] = []
    var failures: [String] = []
    for packet in fixture.packets.dropFirst(3) + [DecodeInput.drain] {
      do { times += try decoder.decode(packet).map(\.pts) }
      catch { failures.append(String(describing: error)) }
    }
    XCTAssertTrue(backlog.sawBackpressure)
    XCTAssertEqual(failures.count, 0, "repeated failures: \(failures.prefix(4))")
    XCTAssertEqual(times, fixture.packets.dropFirst().map(\.pts))
  }

  func testVideoReceivesPastOneFailedFrame() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets([fixture.packets[0]])
    decoder.operations.send = backlog.send
    decoder.operations.receive = droppingFirstFrame()

    let frames = try decoder.decode(fixture.packets[1])
    XCTAssertEqual(frames.map(\.pts), [fixture.packets[1].pts],
                   "a failed output must not leave the pending input untouched")
    XCTAssertEqual(decoder.damagedFrameCount, 1)
  }

  func testAudioReceivesPastOneFailedFrame() async throws {
    let fixture = try await DecodeInput.load("audio_only.m4a", mediaType: .audio)
    let decoder = try fixture.parameters.makeAudioDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(2)))
    decoder.operations.send = backlog.send
    decoder.operations.receive = droppingFirstFrame()

    let frames = try decoder.decode(fixture.packets[2])
    XCTAssertEqual(frames.map(\.pts), [fixture.packets[2].pts])
    XCTAssertEqual(decoder.damagedFrameCount, 1)
  }

  func testVideoStopsReceivingPersistentErrors() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    var calls = 0
    decoder.operations.receive = { _, _ in
      calls += 1
      return calls < 100 ? -EIO : -EAGAIN
    }
    XCTAssertThrowsError(try decoder.decode(fixture.packets[0])) { error in
      guard case FFmpegDecoderError.receiveFailed(-EIO) = error else {
        return XCTFail("persistent receive failure must be reported: \(error)")
      }
    }
    XCTAssertGreaterThan(calls, 1)
    XCTAssertLessThan(calls, 100, "a broken codec must not monopolize the decoding thread")
  }

  func testAudioStopsReceivingPersistentErrors() async throws {
    let fixture = try await DecodeInput.load("audio_only.m4a", mediaType: .audio)
    let decoder = try fixture.parameters.makeAudioDecoder()
    defer { decoder.close() }
    var calls = 0
    decoder.operations.receive = { _, _ in
      calls += 1
      return calls < 100 ? -EIO : -EAGAIN
    }
    XCTAssertThrowsError(try decoder.decode(fixture.packets[1])) { error in
      guard case FFmpegDecoderError.receiveFailed(-EIO) = error else {
        return XCTFail("persistent receive failure must be reported: \(error)")
      }
    }
    XCTAssertGreaterThan(calls, 1)
    XCTAssertLessThan(calls, 100)
  }

  func testVideoRecoversPendingInputAfterAnEarlierSendError() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets([fixture.packets[0]])
    decoder.operations.send = failingAfterAccepting(backlog)
    XCTAssertThrowsError(try decoder.decode(fixture.packets[1]))

    var times: [Int64] = []
    for packet in fixture.packets.dropFirst(2) + [DecodeInput.drain] {
      times += try decoder.decode(packet).map(\.pts)
    }
    XCTAssertTrue(backlog.sawBackpressure)
    XCTAssertEqual(times, fixture.packets.map(\.pts), "the previous error must not poison later calls")
  }

  func testAudioRecoversPendingInputAfterAnEarlierSendError() async throws {
    let fixture = try await DecodeInput.load("audio_only.m4a", mediaType: .audio)
    let decoder = try fixture.parameters.makeAudioDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(2)))
    decoder.operations.send = failingAfterAccepting(backlog)
    XCTAssertThrowsError(try decoder.decode(fixture.packets[2]))

    var times: [Int64] = []
    for packet in fixture.packets.dropFirst(3) + [DecodeInput.drain] {
      times += try decoder.decode(packet).map(\.pts)
    }
    XCTAssertTrue(backlog.sawBackpressure)
    XCTAssertEqual(times, fixture.packets.dropFirst().map(\.pts))
  }

  func testDrainRetriesItsSignalAndFlushAllowsReuse() async throws {
    let fixture = try await DecodeInput.load("b_frames.mkv", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    var times: [Int64] = []
    for packet in fixture.packets { times += try decoder.decode(packet).map(\.pts) }
    let beforeDrain = times.count
    var refusedDrain = false
    decoder.operations.send = { context, packet in
      if packet?.pointee.data == nil, !refusedDrain {
        refusedDrain = true
        return -EAGAIN
      }
      return avcodec_send_packet(context, packet)
    }
    times += try decoder.decode(DecodeInput.drain).map(\.pts)
    XCTAssertTrue(refusedDrain)
    XCTAssertGreaterThan(times.count, beforeDrain, "the delayed tail must survive backpressure")
    XCTAssertEqual(times, fixture.packets.map(\.pts).sorted())
    XCTAssertThrowsError(try decoder.decode(DecodeInput.drain)) { error in
      guard case FFmpegDecoderError.sendFailed(FFmpegErrorCode.endOfFileRaw) = error else {
        return XCTFail("a second drain must still report EOF: \(error)")
      }
    }
    decoder.flush()
    var afterFlush: [Int64] = []
    for packet in fixture.packets + [DecodeInput.drain] {
      afterFlush += try decoder.decode(packet).map(\.pts)
    }
    XCTAssertEqual(afterFlush, times)
  }

  func testVideoKeepsRecoveredFramesWhenTheRetriedPacketIsDamaged() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(2)))
    decoder.operations.send = backlog.send
    XCTAssertThrowsError(try decoder.decode(DecodeInput.damaged))
    XCTAssertTrue(backlog.sawBackpressure)

    var times: [Int64] = []
    for packet in fixture.packets.dropFirst(2) + [DecodeInput.drain] {
      times += try decoder.decode(packet).map(\.pts)
    }
    XCTAssertEqual(times, fixture.packets.map(\.pts), "bad input must not discard earlier healthy output")
  }

  func testAudioKeepsRecoveredFramesWhenTheRetriedPacketIsDamaged() async throws {
    let fixture = try await DecodeInput.load("audio_only.m4a", mediaType: .audio)
    let decoder = try fixture.parameters.makeAudioDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(3)))
    decoder.operations.send = backlog.send
    XCTAssertThrowsError(try decoder.decode(DecodeInput.damaged))
    XCTAssertTrue(backlog.sawBackpressure)

    var times: [Int64] = []
    for packet in fixture.packets.dropFirst(3) + [DecodeInput.drain] {
      times += try decoder.decode(packet).map(\.pts)
    }
    XCTAssertEqual(times, fixture.packets.dropFirst().map(\.pts))
  }

  func testFlushDiscardsFramesSavedBeforeARejectedPacket() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(2)))
    decoder.operations.send = backlog.send
    XCTAssertThrowsError(try decoder.decode(DecodeInput.damaged))

    decoder.flush()
    var times: [Int64] = []
    for packet in fixture.packets + [DecodeInput.drain] {
      times += try decoder.decode(packet).map(\.pts)
    }
    XCTAssertEqual(times, fixture.packets.map(\.pts), "saved frames from before the seek must not leak through")
  }

  func testDrainDeliversFramesSavedBeforeARejectedPacket() async throws {
    let fixture = try await DecodeInput.load("moov_at_end.mp4", mediaType: .video)
    let decoder = try fixture.videoDecoder()
    defer { decoder.close() }
    let backlog = PendingPackets(Array(fixture.packets.prefix(2)))
    decoder.operations.send = backlog.send
    XCTAssertThrowsError(try decoder.decode(DecodeInput.damaged))
    let frames = try decoder.decode(DecodeInput.drain)
    XCTAssertEqual(frames.map(\.pts), fixture.packets.prefix(2).map(\.pts))
    XCTAssertThrowsError(try decoder.decode(DecodeInput.drain))
  }

  /// Some send failures occur after FFmpeg retains compressed input.
  /// Returning a failure here models that boundary, without needing a
  /// hardware decoder to lose its session during this test.
  private func failingAfterAccepting(_ backlog: PendingPackets) -> (
    UnsafeMutablePointer<AVCodecContext>, UnsafePointer<AVPacket>?
  ) -> Int32 {
    var failed = false
    return { context, packet in
      let status = backlog.send(context, packet)
      if !failed {
        failed = true
        XCTAssertEqual(status, 0)
        return -EIO
      }
      return status
    }
  }

  /// A postprocessing failure consumes one decoded frame, while compressed
  /// input can still be pending. Subsequent calls use the real codec.
  private func droppingFirstFrame() -> (
    UnsafeMutablePointer<AVCodecContext>, UnsafeMutablePointer<AVFrame>
  ) -> Int32 {
    var dropped = false
    return { context, frame in
      let status = avcodec_receive_frame(context, frame)
      if status >= 0, !dropped {
        dropped = true
        av_frame_unref(frame)
        return -EIO
      }
      return status
    }
  }
}

private final class PendingPackets {
  private var packets: [FFmpegPacket]
  private(set) var sawBackpressure = false

  init(_ packets: [FFmpegPacket]) { self.packets = packets }

  func send(_ context: UnsafeMutablePointer<AVCodecContext>, _ packet: UnsafePointer<AVPacket>?) -> Int32 {
    for pending in packets {
      let status = withPacket(pending) { avcodec_send_packet(context, $0) }
      XCTAssertEqual(status, 0, "the pending packet must enter the real codec")
    }
    packets.removeAll()
    let status = avcodec_send_packet(context, packet)
    if status == -EAGAIN { sawBackpressure = true }
    return status
  }

  private func withPacket(_ packet: FFmpegPacket, _ body: (UnsafePointer<AVPacket>) -> Int32) -> Int32 {
    guard let raw = av_packet_alloc() else { return -ENOMEM }
    defer {
      var owned: UnsafeMutablePointer<AVPacket>? = raw
      av_packet_free(&owned)
    }
    let status = av_new_packet(raw, Int32(packet.data.count))
    guard status >= 0 else { return status }
    packet.data.withUnsafeBytes { bytes in
      if let source = bytes.baseAddress, let target = raw.pointee.data {
        memcpy(target, source, packet.data.count)
      }
    }
    raw.pointee.pts = packet.pts
    raw.pointee.dts = packet.dts
    return body(UnsafePointer(raw))
  }
}

private struct DecodeInput {
  let parameters: FFmpegCodecParameters
  let packets: [FFmpegPacket]

  static let drain = FFmpegPacket(
    streamIndex: 0, data: Data(), pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
    duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false)

  static let damaged = FFmpegPacket(
    streamIndex: 0, data: Data([0xFF, 0xFF, 0xFF]), pts: 0, dts: 0,
    duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false)

  func videoDecoder() throws -> FFmpegVideoDecoder {
    try parameters.withUnsafeParameters {
      try FFmpegVideoDecoder(
        parameters: UnsafeMutablePointer(mutating: $0),
        timeBaseNum: packets[0].timeBaseNum, timeBaseDen: packets[0].timeBaseDen,
        containerAspect: AVRational(num: 0, den: 1), preferHardware: false, softwareThreadCount: 1)
    }
  }

  static func load(_ name: String, mediaType: FFmpegMediaType) async throws -> DecodeInput {
    let reader = DecodeBytes(data: try Data(contentsOf: FixtureLocator.url(for: name)))
    let demux = FFmpegDemuxer(callbacks: FFmpegIOCallbacks(
      read: { await reader.read($0) }, seek: { await reader.seek($0) },
      totalLength: { await reader.length }, canSeek: true), configuration: .init())
    do {
      try await demux.open()
      let streams = await demux.streams()
      let stream = try XCTUnwrap(streams.first { $0.mediaType == mediaType })
      let parameters: FFmpegCodecParameters
      if mediaType == .video {
        let decoder = try await demux.makeVideoDecoder(streamIndex: stream.index, preferHardware: false)
        defer { decoder.close() }
        parameters = try XCTUnwrap(decoder.parameters)
      } else {
        let decoder = try await demux.makeAudioDecoder(streamIndex: stream.index)
        defer { decoder.close() }
        parameters = try XCTUnwrap(decoder.parameters)
      }
      var packets: [FFmpegPacket] = []
      while let packet = try await demux.readPacket() {
        if packet.streamIndex == stream.index { packets.append(packet) }
      }
      await demux.close()
      XCTAssertGreaterThan(packets.count, 2)
      return DecodeInput(parameters: parameters, packets: packets)
    } catch {
      await demux.close()
      throw error
    }
  }
}

private actor DecodeBytes {
  let data: Data
  var position = 0
  var length: Int64? { Int64(data.count) }
  init(data: Data) { self.data = data }
  func read(_ count: Int) -> Data {
    let end = min(position + count, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }
  func seek(_ offset: Int64) { position = min(Int(offset), data.count) }
}
