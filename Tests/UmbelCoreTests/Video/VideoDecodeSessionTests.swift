import CoreMedia
import VideoToolbox
import XCTest
@testable import UmbelCore

private enum Fixture {
  static func url(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
      .appendingPathComponent(name)
  }
}

final class VideoDecodeSessionTests: XCTestCase {
  /// Frame numbers at 25 a second of b_frames.mkv decoded whole — a keyframe
  /// every 25, then B B P, the B frames referred to by nothing — with the
  /// frames before two seconds hidden.
  func testHiddenFramesNothingRefersToAreSkipped() async throws {
    let source = try UmbelFileSource(url: Fixture.url("b_frames.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }
    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decodeSession = VideoDecodeSession(
      decoder: try await session.makeVideoDecoder(for: video.id, preferHardware: false))
    addTeardownBlock { await decodeSession.close() }

    var frames: [Int] = []
    while let packet = try await session.nextPacket() {
      guard packet.trackID == video.id else { continue }
      let hidden = packet.presentationTime.seconds < 2
      frames += try await decodeSession.decode(packet, hidden: hidden)
        .map { Int(($0.presentationTime.seconds * 25).rounded()) }
    }
    frames += try await decodeSession.drain().map { Int(($0.presentationTime.seconds * 25).rounded()) }
    let references = (0..<50).filter { $0 % 25 % 3 == 0 }
    XCTAssertEqual(frames, references + Array(50..<100))
    let counted = await decodeSession.decodedFrameCount
    XCTAssertEqual(counted, frames.count)
  }

  /// A seek stops skipping: the frame it lands on may be one nothing refers to.
  func testFlushStopsSkipping() async throws {
    let source = try UmbelFileSource(url: Fixture.url("b_frames.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }
    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decodeSession = VideoDecodeSession(
      decoder: try await session.makeVideoDecoder(for: video.id, preferHardware: false))
    addTeardownBlock { await decodeSession.close() }

    await decodeSession.setSkipsNonReference(true)
    let skipping = await decodeSession.skipsNonReference
    XCTAssertTrue(skipping)
    await decodeSession.flush()
    let afterSeek = await decodeSession.skipsNonReference
    XCTAssertFalse(afterSeek)
  }

  func testDecodesFixtureIntoVideoFrames() async throws {
    let source = try UmbelFileSource(url: Fixture.url("moov_at_end.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoder = try await session.makeVideoDecoder(for: video.id, preferHardware: false)
    let decodeSession = VideoDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var count = 0
    var firstTime: CMTime?
    while let packet = try await session.nextPacket(), count < 5 {
      guard packet.trackID == video.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        if firstTime == nil { firstTime = frame.presentationTime }
        XCTAssertEqual(frame.width, 160)
        XCTAssertEqual(frame.height, 120)
        // The fixture declares no matrix. The description says so as it is,
        // and rendering treats it as BT.709 — the two are kept apart, or
        // "declared 709" could not be told from "declared nothing".
        XCTAssertEqual(frame.color.matrix, .unspecified)
        XCTAssertEqual(frame.color.range, .limited)
        count += 1
      }
    }
    XCTAssertGreaterThan(count, 0)
    let start = try XCTUnwrap(firstTime)
    XCTAssertTrue(start.isValid)
  }

  /// Made anew, with a decoder of its own: iOS takes the hardware decoder
  /// away from an app in the background, and the old one failed its first
  /// second of frames after coming back. Decoding goes on from a seek.
  func testRenewingMakesANewDecoderThatDecodesOn() async throws {
    let source = try UmbelFileSource(url: Fixture.url("moov_at_end.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }
    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decodeSession = VideoDecodeSession(
      decoder: try await session.makeVideoDecoder(for: video.id, preferHardware: true))
    addTeardownBlock { await decodeSession.close() }

    try await decodeSession.renew()
    let rebuilt = await decodeSession.rebuildCount
    XCTAssertEqual(rebuilt, 1, "a new decoder")
    let hardware = await decodeSession.isHardwareAccelerated
    let preferred = hardware || VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) == false
    XCTAssertTrue(preferred, "made as the old one was: hardware first")
    var frames = 0
    while let packet = try await session.nextPacket(), frames < 3 {
      guard packet.trackID == video.id else { continue }
      frames += try await decodeSession.decode(packet).count
    }
    XCTAssertGreaterThan(frames, 0, "decodes on")
  }

  /// Pins the kind of error met earlier: the wrong time base stretches the
  /// frame interval many times over.
  func testFrameIntervalIsPlausible() async throws {
    let source = try UmbelFileSource(url: Fixture.url("moov_at_end.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoder = try await session.makeVideoDecoder(for: video.id, preferHardware: false)
    let decodeSession = VideoDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var times: [Double] = []
    while let packet = try await session.nextPacket(), times.count < 6 {
      guard packet.trackID == video.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        times.append(frame.presentationTime.seconds)
      }
    }
    XCTAssertGreaterThan(times.count, 2)
    // The fixture is 25 frames a second: intervals of about 0.04 s.
    for index in 1..<times.count {
      let interval = times[index] - times[index - 1]
      XCTAssertEqual(interval, 0.04, accuracy: 0.02,
                     "the interval is off the nominal rate: the wrong time base")
    }
  }

  func testMakingVideoDecoderForAudioTrackThrows() async throws {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    do {
      _ = try await session.makeVideoDecoder(for: audio.id, preferHardware: false)
      XCTFail("making a video decoder for an audio track throws")
    } catch {
      // As expected
    }
  }

  /// The last frames are not lost: with a decoder that holds frames back,
  /// only draining brings them out. The total is checked rather than what
  /// the drain gave — without B frames a drain rightly gives none.
  func testDrainYieldsEveryRemainingFrame() async throws {
    let source = try UmbelFileSource(url: Fixture.url("sync_check.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoder = try await session.makeVideoDecoder(for: video.id, preferHardware: false)
    let decodeSession = VideoDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var count = 0
    while let packet = try await session.nextPacket() {
      guard packet.trackID == video.id else { continue }
      count += try await decodeSession.decode(packet).count
    }
    count += try await decodeSession.drain().count

    XCTAssertEqual(count, 180, "the fixture is 6 s at 30 frames a second; the container declares 180")
  }

  /// Draining is idempotent: the second time there is nothing to give.
  func testDrainIsIdempotent() async throws {
    let source = try UmbelFileSource(url: Fixture.url("sync_check.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    let decoder = try await session.makeVideoDecoder(for: video.id, preferHardware: false)
    let decodeSession = VideoDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    while let packet = try await session.nextPacket() {
      guard packet.trackID == video.id else { continue }
      _ = try await decodeSession.decode(packet)
    }
    _ = try await decodeSession.drain()
    let second = try await decodeSession.drain()
    XCTAssertTrue(second.isEmpty, "a drained decoder has no second batch")
  }
}
