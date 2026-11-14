import XCTest
@testable import UmbelFFmpegSupport

final class FFmpegResamplerTests: XCTestCase {
  /// Interleaved 16-bit integers to planar float32: the most common
  /// normalisation.
  func testConvertsInterleavedInt16ToPlanarFloat() throws {
    let resampler = try FFmpegResampler(
      inputFormat: .signedInt16Interleaved, channelCount: 2, sampleRate: 48_000)
    defer { resampler.release() }

    // Left channel all positive peaks, right all negative, interleaved.
    var interleaved: [Int16] = []
    for _ in 0..<4 { interleaved.append(Int16.max); interleaved.append(Int16.min) }

    let output = try interleaved.withUnsafeMutableBytes { raw -> [Float] in
      try resampler.convert(planes: [raw.baseAddress!], frameCount: 4)
    }

    XCTAssertEqual(output.count, 8, "4 frames × 2 channels")
    // Planar: the first 4 are the left channel, the last 4 the right.
    for index in 0..<4 {
      XCTAssertEqual(output[index], 1.0, accuracy: 0.001, "the left channel is at the positive peak")
      XCTAssertEqual(output[4 + index], -1.0, accuracy: 0.001, "the right channel is at the negative peak")
    }
  }

  func testPlanarFloatInputPassesThroughUnchanged() throws {
    let resampler = try FFmpegResampler(
      inputFormat: .float32Planar, channelCount: 2, sampleRate: 44_100)
    defer { resampler.release() }

    var left: [Float] = [0.25, 0.5]
    var right: [Float] = [-0.25, -0.5]
    let output = try left.withUnsafeMutableBytes { leftRaw -> [Float] in
      try right.withUnsafeMutableBytes { rightRaw -> [Float] in
        try resampler.convert(
          planes: [leftRaw.baseAddress!, rightRaw.baseAddress!], frameCount: 2)
      }
    }

    XCTAssertEqual(output.count, 4)
    XCTAssertEqual(output[0], 0.25, accuracy: 0.0001)
    XCTAssertEqual(output[1], 0.5, accuracy: 0.0001)
    XCTAssertEqual(output[2], -0.25, accuracy: 0.0001)
    XCTAssertEqual(output[3], -0.5, accuracy: 0.0001)
  }

  func testMonoIsSupported() throws {
    let resampler = try FFmpegResampler(
      inputFormat: .float32Planar, channelCount: 1, sampleRate: 48_000)
    defer { resampler.release() }
    var mono: [Float] = [0.1, 0.2, 0.3]
    let output = try mono.withUnsafeMutableBytes { raw -> [Float] in
      try resampler.convert(planes: [raw.baseAddress!], frameCount: 3)
    }
    XCTAssertEqual(output.count, 3)
    XCTAssertEqual(output[2], 0.3, accuracy: 0.0001)
  }

  func testZeroFrameCountReturnsEmpty() throws {
    let resampler = try FFmpegResampler(
      inputFormat: .float32Planar, channelCount: 2, sampleRate: 48_000)
    defer { resampler.release() }
    var scratch: [Float] = [0]
    let output = try scratch.withUnsafeMutableBytes { raw -> [Float] in
      try resampler.convert(planes: [raw.baseAddress!], frameCount: 0)
    }
    XCTAssertTrue(output.isEmpty)
  }

  /// What the output is prepared in may differ from what the content is
  /// encoded in — midway, even: both the rate and the channels convert.
  func testConvertsTheRateAndTheChannelCount() throws {
    let resampler = try FFmpegResampler(
      inputFormat: .float32Planar, inputChannelCount: 1, inputSampleRate: 44_100,
      outputChannelCount: 2, outputSampleRate: 48_000)
    var input = [Float](repeating: 0.25, count: 4_410)
    let output = try input.withUnsafeMutableBytes { raw in
      try resampler.convert(planes: [raw.baseAddress!], frameCount: 4_410)
    }
    XCTAssertEqual(output.count % 2, 0, "two planes")
    XCTAssertEqual(Double(output.count / 2), 4_800, accuracy: 100, "a tenth of a second at 48 kHz")
  }

  func testPlanarLayoutFlagMatchesFormat() {
    XCTAssertTrue(FFmpegResampler.InputFormat.float32Planar.isPlanarLayout)
    XCTAssertTrue(FFmpegResampler.InputFormat.signedInt16Planar.isPlanarLayout)
    XCTAssertFalse(FFmpegResampler.InputFormat.signedInt16Interleaved.isPlanarLayout)
    XCTAssertFalse(FFmpegResampler.InputFormat.float32Interleaved.isPlanarLayout)
  }

  func testReleaseIsIdempotent() throws {
    let resampler = try FFmpegResampler(
      inputFormat: .float32Planar, channelCount: 2, sampleRate: 48_000)
    resampler.release()
    resampler.release()
  }
}
