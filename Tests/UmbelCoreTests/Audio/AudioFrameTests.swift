import CoreMedia
import XCTest
@testable import UmbelCore

final class AudioFrameTests: XCTestCase {
  private func makeFrame(frameCount: Int, channelCount: Int, sampleRate: Double) -> AudioFrame {
    AudioFrame(
      presentationTime: CMTime(seconds: 1, preferredTimescale: 48_000),
      sampleRate: sampleRate,
      channelCount: channelCount,
      frameCount: frameCount,
      samples: [Float](repeating: 0, count: frameCount * channelCount)
    )
  }

  func testSamplesArePlanarSized() {
    let frame = makeFrame(frameCount: 4, channelCount: 2, sampleRate: 48_000)
    // Planar: channel 0's 4 samples, then channel 1's 4.
    XCTAssertEqual(frame.samples.count, frame.frameCount * frame.channelCount)
  }

  func testDurationMatchesSampleCount() {
    let frame = makeFrame(frameCount: 48_000, channelCount: 2, sampleRate: 48_000)
    XCTAssertEqual(frame.duration.seconds, 1.0, accuracy: 0.0001)
  }

  func testShortFrameDuration() {
    let frame = makeFrame(frameCount: 1024, channelCount: 2, sampleRate: 48_000)
    XCTAssertEqual(frame.duration.seconds, 1024.0 / 48_000.0, accuracy: 0.000001)
  }

  func testZeroSampleRateGivesInvalidDuration() {
    let frame = makeFrame(frameCount: 1024, channelCount: 2, sampleRate: 0)
    XCTAssertFalse(frame.duration.isValid, "a zero sample rate gives no inf")
  }

  func testMonoIsSupported() {
    let frame = makeFrame(frameCount: 10, channelCount: 1, sampleRate: 44_100)
    XCTAssertEqual(frame.samples.count, 10)
  }
}
