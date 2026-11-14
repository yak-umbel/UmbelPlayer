import CoreMedia
import XCTest
@testable import UmbelCore

/// The system's renderer took sound in buffers of 40 samples — TrueHD's
/// frames — said it was rendering, and played a blip, then nothing. Frames
/// that short are joined into one of 20 ms or more before they go to it;
/// longer ones go as they are.
final class AudioFrameBatcherTests: XCTestCase {
  /// `count` samples at 48 kHz from sample `first`, two channels: channel c
  /// holds c * 100_000 + the sample's index in the stream.
  private func frame(from first: Int, count: Int, channels: Int = 2, rate: Double = 48_000) -> AudioFrame {
    var samples: [Float] = []
    for channel in 0..<channels { samples += (first..<(first + count)).map { Float(channel * 100_000 + $0) } }
    return AudioFrame(
      presentationTime: CMTime(value: CMTimeValue(first), timescale: CMTimeScale(rate)), sampleRate: rate,
      channelCount: channels, frameCount: count, samples: samples)
  }

  func testFramesLongEnoughGoAsTheyAre() {
    var batcher = AudioFrameBatcher()
    let aac = frame(from: 0, count: 1024)
    let out = batcher.add(aac)
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(out.first?.samples, aac.samples)
    XCTAssertEqual(out.first?.presentationTime, aac.presentationTime)
  }

  /// Twenty-four TrueHD frames make 960 samples, 20 ms: one frame, from the
  /// first one's time, each channel's samples in order.
  func testShortFramesAreJoined() throws {
    var batcher = AudioFrameBatcher()
    var out: [AudioFrame] = []
    for index in 0..<24 { out += batcher.add(frame(from: index * 40, count: 40)) }
    XCTAssertEqual(out.count, 1)
    let joined = try XCTUnwrap(out.first)
    XCTAssertEqual(joined.frameCount, 960)
    XCTAssertEqual(joined.presentationTime, CMTime(value: 0, timescale: 48_000))
    XCTAssertEqual(joined.samples, frame(from: 0, count: 960).samples)
  }

  /// Sound that does not carry on from what is held — after a gap in the
  /// timestamps — sends what is held first; so does another format.
  func testABreakSendsWhatIsHeldFirst() throws {
    var batcher = AudioFrameBatcher()
    _ = batcher.add(frame(from: 0, count: 40))
    _ = batcher.add(frame(from: 40, count: 40))
    let afterGap = batcher.add(frame(from: 48_000, count: 40))
    XCTAssertEqual(afterGap.map(\.frameCount), [80])
    let otherFormat = batcher.add(frame(from: 48_040, count: 40, channels: 6))
    XCTAssertEqual(otherFormat.map(\.frameCount), [40])
    XCTAssertEqual(otherFormat.first?.presentationTime, CMTime(value: 48_000, timescale: 48_000))
  }

  /// A seek: what is held belongs to before it.
  func testResetDropsWhatIsHeld() {
    var batcher = AudioFrameBatcher()
    _ = batcher.add(frame(from: 0, count: 40))
    batcher.reset()
    let out = batcher.add(frame(from: 96_000, count: 1024))
    XCTAssertEqual(out.map(\.frameCount), [1024])
  }
}
