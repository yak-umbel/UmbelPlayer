import CoreMedia
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

final class AudioDecodeSessionTests: XCTestCase {
  func testDecodesFixtureIntoAudioFrames() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await session.makeAudioDecoder(for: audio.id)
    let decodeSession = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var totalFrames = 0
    var firstTime: CMTime?
    while let packet = try await session.nextPacket() {
      guard packet.trackID == audio.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        if firstTime == nil { firstTime = frame.presentationTime }
        XCTAssertEqual(frame.channelCount, 2)
        XCTAssertEqual(frame.sampleRate, 48_000, accuracy: 0.001)
        totalFrames += frame.frameCount
      }
    }

    XCTAssertGreaterThan(totalFrames, 80_000)
    let start = try XCTUnwrap(firstTime)
    XCTAssertTrue(start.isValid)
    XCTAssertLessThan(start.seconds, 0.2, "the first frame is near the start of the content")
  }

  /// TrueHD's decoder puts out interleaved 32-bit integers, a format the
  /// conversion to float did not know: every packet failed, and the film
  /// with it. Its six channels, a 440 Hz tone at the encoder's level, come
  /// out as float — not silence.
  func testTrueHDDecodesIntoFloatChannels() async throws {
    let source = try UmbelFileSource(url: Fixture.url("truehd_51.mka"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await session.makeAudioDecoder(for: audio.id)
    let decodeSession = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var totalFrames = 0
    var loudest: Float = 0
    while let packet = try await session.nextPacket() {
      guard packet.trackID == audio.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        XCTAssertEqual(frame.channelCount, 6)
        totalFrames += frame.frameCount
        loudest = max(loudest, frame.samples.map(abs).max() ?? 0)
      }
    }
    XCTAssertGreaterThan(totalFrames, 40_000)
    XCTAssertGreaterThan(loudest, 0.05, "a tone, not silence")
    XCTAssertLessThanOrEqual(loudest, 1.0, "scaled to float's range")
  }

  /// Pins a bug met for real: the decoder once read timestamps packed in
  /// microseconds by **the stream's** time base, stretching frame intervals
  /// 20.8 times (0.0213 s became 0.4444 s). The interval has to equal
  /// samples over sample rate.
  func testFrameIntervalMatchesSampleCount() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await session.makeAudioDecoder(for: audio.id)
    let decodeSession = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var previous: AudioFrame?
    var checked = 0
    while let packet = try await session.nextPacket(), checked < 10 {
      guard packet.trackID == audio.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        defer { previous = frame }
        guard let last = previous else { continue }
        let interval = frame.presentationTime.seconds - last.presentationTime.seconds
        let expected = Double(last.frameCount) / last.sampleRate
        XCTAssertEqual(interval, expected, accuracy: 0.0005,
                       "the interval equals samples over sample rate; off, the wrong time base was used")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 0)
  }

  func testTimestampsAreMonotonic() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await session.makeAudioDecoder(for: audio.id)
    let decodeSession = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var previous = -Double.infinity
    var last = 0.0
    while let packet = try await session.nextPacket() {
      guard packet.trackID == audio.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        XCTAssertGreaterThan(frame.presentationTime.seconds, previous)
        previous = frame.presentationTime.seconds
        last = previous
      }
    }
    // The fixture is 2 seconds; the last frame falls about there, not at 40
    // seconds as a stretched time would put it.
    XCTAssertGreaterThan(last, 1.5)
    XCTAssertLessThan(last, 2.5, "the length is off the fixture: time is converted wrongly")
  }

  func testMakingDecoderForVideoTrackThrows() async throws {
    let source = try UmbelFileSource(url: Fixture.url("multi_track.mkv"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let video = try XCTUnwrap(tracks.first { $0.kind == .video })
    do {
      _ = try await session.makeAudioDecoder(for: video.id)
      XCTFail("making an audio decoder for a video track throws")
    } catch {
      // As expected
    }
  }

  func testCloseIsIdempotent() async throws {
    let source = try UmbelFileSource(url: Fixture.url("audio_only.m4a"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }
    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await session.makeAudioDecoder(for: audio.id)
    let decodeSession = AudioDecodeSession(decoder: decoder)
    await decodeSession.close()
    await decodeSession.close()
  }

  /// Audio too: the tail must not be lost. The length decoded is checked, not
  /// the frame count, which the decoder's warm-up at the first frame
  /// affects; the length says directly whether the tail was lost.
  func testDrainKeepsTheTailOfTheContent() async throws {
    let source = try UmbelFileSource(url: Fixture.url("sync_check.mp4"))
    let session = DemuxSession(source: source)
    try await session.open()
    addTeardownBlock { await session.close() }

    let tracks = await session.tracks
    let audio = try XCTUnwrap(tracks.first { $0.kind == .audio })
    let decoder = try await session.makeAudioDecoder(for: audio.id)
    let decodeSession = AudioDecodeSession(decoder: decoder)
    addTeardownBlock { await decodeSession.close() }

    var samples = 0
    var rate: Double = 0
    while let packet = try await session.nextPacket() {
      guard packet.trackID == audio.id else { continue }
      for frame in try await decodeSession.decode(packet) {
        samples += frame.frameCount
        rate = frame.sampleRate
      }
    }
    for frame in try await decodeSession.drain() {
      samples += frame.frameCount
      rate = frame.sampleRate
    }

    XCTAssertEqual(rate, 48_000)
    XCTAssertEqual(Double(samples) / rate, 6.0, accuracy: 0.05, "the fixture is 6 seconds")
  }
}
