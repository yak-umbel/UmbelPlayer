import CoreVideo
import XCTest
@testable import UmbelFFmpegSupport

private actor FixtureReader {
  private let data: Data
  private var position = 0

  init(named name: String) throws { data = try Data(contentsOf: FixtureLocator.url(for: name)) }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }

  var length: Int64 { Int64(data.count) }
}

/// The decoder reports which frames are interlaced, which field is first,
/// and how long each lasts — what turning one frame into two pictures needs.
final class FFmpegInterlaceTests: XCTestCase {
  private func decodedFrames(of name: String) async throws -> [FFmpegVideoFrame] {
    let reader = try FixtureReader(named: name)
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
    let decoder = try await demuxer.makeVideoDecoder(streamIndex: video.index, preferHardware: false)
    defer { decoder.close() }
    var frames: [FFmpegVideoFrame] = []
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == video.index else { continue }
      frames += try decoder.decode(packet)
    }
    frames += try decoder.decode(FFmpegPacket(
      streamIndex: 0, data: Data(), pts: FFmpegPacket.noTimestamp, dts: FFmpegPacket.noTimestamp,
      duration: 0, timeBaseNum: 0, timeBaseDen: 0, isKeyframe: false))
    XCTAssertFalse(frames.isEmpty, name)
    return frames
  }

  func testInterlacedFramesSayWhichFieldComesFirst() async throws {
    for frame in try await decodedFrames(of: "interlaced_tff.ts") {
      XCTAssertTrue(frame.isInterlaced)
      XCTAssertTrue(frame.topFieldFirst)
    }
    for frame in try await decodedFrames(of: "interlaced_bff.ts") {
      XCTAssertTrue(frame.isInterlaced)
      XCTAssertFalse(frame.topFieldFirst)
    }
  }

  func testProgressiveFramesAreNotInterlaced() async throws {
    for frame in try await decodedFrames(of: "short.mp4") {
      XCTAssertFalse(frame.isInterlaced)
    }
  }

  /// What the stream itself declares as its frame rate — the sequence header's
  /// for MPEG-2, the timing information's for H.264 — is carried on the frame.
  /// A frame of two field pictures takes its duration from the first field's
  /// packet, one field long; the declared frame rate is how the real period
  /// is told from it.
  func testFramesCarryTheFrameRateTheStreamDeclares() async throws {
    for frame in try await decodedFrames(of: "interlaced_tff.ts") {
      XCTAssertEqual(frame.frameRateNum, 25)
      XCTAssertEqual(frame.frameRateDen, 1)
    }
  }

  /// HEVC does not pair the fields of a field-coded stream: each comes out as
  /// a picture of its own, half the height, flagged interlaced. Such a picture
  /// is no woven frame and must not be reported as one. Codecs whose frames
  /// are woven pairs are.
  func testOnlyCodecsThatPairFieldsReportInterlacedFrames() {
    for name in ["h264", "mpeg2video", "vc1", "mpeg4", "mjpeg", "prores", "dvvideo"] {
      XCTAssertTrue(FFmpegVideoDecoder.deliversWovenFields(codecName: name), name)
    }
    for name in ["hevc", "vvc"] {
      XCTAssertFalse(FFmpegVideoDecoder.deliversWovenFields(codecName: name), name)
    }
  }

  /// What a frame is reported as: interlaced only where the codec's frames
  /// are woven pairs *and* the decoder flagged it. A HEVC picture the decoder
  /// flags interlaced is one field of two, never reported as a woven frame.
  func testAFrameIsReportedInterlacedOnlyWhereItsCodecWeavesFields() {
    XCTAssertTrue(FFmpegVideoDecoder.reportsInterlaced(flagged: true, codecName: "h264"))
    XCTAssertTrue(FFmpegVideoDecoder.reportsInterlaced(flagged: true, codecName: "mpeg2video"))
    XCTAssertFalse(FFmpegVideoDecoder.reportsInterlaced(flagged: false, codecName: "h264"), "not flagged")
    XCTAssertFalse(FFmpegVideoDecoder.reportsInterlaced(flagged: true, codecName: "hevc"), "a field, not a frame")
    XCTAssertFalse(FFmpegVideoDecoder.reportsInterlaced(flagged: true, codecName: "vvc"))
  }

  /// 25 frames a second in a 90 kHz time base: 3600 ticks each, taken from
  /// the packets the frames were decoded from.
  func testFramesCarryTheirPacketsDuration() async throws {
    for frame in try await decodedFrames(of: "interlaced_tff.ts") {
      XCTAssertEqual(frame.timeBaseNum, 1)
      XCTAssertEqual(frame.timeBaseDen, 90_000)
      XCTAssertEqual(frame.duration, 3600)
    }
  }

  // MARK: Chroma of 4:2:2 frames

  /// The (Cb, Cr) of the chroma plane of a converted frame, on one of its
  /// rows, in the middle of the picture.
  private func chroma(of frame: FFmpegVideoFrame, row: Int) throws -> (cb: Int, cr: Int) {
    let buffer = frame.pixelBuffer
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let plane = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
    XCTAssertLessThan(row, CVPixelBufferGetHeightOfPlane(buffer, 1))
    let sample = plane + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
      + CVPixelBufferGetWidthOfPlane(buffer, 1) / 2 * 2
    return (Int(sample[0]), Int(sample[1]))
  }

  /// Interlaced 4:2:2 whose top field is one colour and bottom field another.
  /// Turned into 4:2:0 as one picture, the rows of both fields average into
  /// grey; turned field by field, the chroma rows go on belonging to their
  /// fields — the even ones to the top, the odd to the bottom — as the rows of
  /// a 4:2:0 interlaced picture do.
  func testAnInterlaced422FrameKeepsEachFieldsOwnChroma() async throws {
    let frames = try await decodedFrames(of: "interlaced_422.ts")
    XCTAssertEqual(frames.count, 25)
    for frame in frames {
      XCTAssertTrue(frame.isInterlaced)
      for row in 20..<24 {
        let (cb, cr) = try chroma(of: frame, row: row)
        let top = row % 2 == 0
        XCTAssertEqual(cb, top ? 64 : 192, accuracy: 20, "Cb of row \(row)")
        XCTAssertEqual(cr, top ? 192 : 64, accuracy: 20, "Cr of row \(row)")
      }
    }
  }

  /// Progressive 4:2:2 keeps its full-height chroma instead of averaging
  /// neighbouring rows into a 4:2:0 intermediate.
  func testAProgressive422FrameKeepsItsChromaRows() async throws {
    let frames = try await decodedFrames(of: "progressive_422.ts")
    XCTAssertEqual(frames.count, 25)
    for frame in frames {
      XCTAssertFalse(frame.isInterlaced)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.pixelBuffer), kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange)
      for row in 20..<24 {
        let (cb, cr) = try chroma(of: frame, row: row)
        XCTAssertEqual(cb, row % 2 == 0 ? 64 : 192, accuracy: 20, "Cb of row \(row)")
        XCTAssertEqual(cr, row % 2 == 0 ? 192 : 64, accuracy: 20, "Cr of row \(row)")
      }
    }
  }
}
