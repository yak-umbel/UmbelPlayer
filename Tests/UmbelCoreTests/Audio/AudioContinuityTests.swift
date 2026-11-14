import CoreMedia
import XCTest
@testable import UmbelCore

/// Sound handed to the output keeps its place on the timeline: outputs time
/// what they play by the samples played, so a gap has to be played as
/// silence and an overlap left out.
final class AudioContinuityTests: XCTestCase {
  /// A thousand samples a second, two channels: sample `i` of channel `c`
  /// holds `c * 1000 + i`.
  private func frame(at start: Double, seconds: Double, channels: Int = 2) -> AudioFrame {
    let count = Int((seconds * 1000).rounded())
    var samples: [Float] = []
    for channel in 0..<channels { samples += (0..<count).map { Float(channel * 1000 + $0) } }
    return AudioFrame(
      presentationTime: CMTime(seconds: start, preferredTimescale: 1_000_000),
      sampleRate: 1000, channelCount: channels, frameCount: count, samples: samples)
  }

  private func seconds(_ frames: [AudioFrame]) -> Double {
    frames.reduce(0) { $0 + Double($1.frameCount) / $1.sampleRate }
  }

  func testSoundBackToBackPassesUnchanged() {
    var continuity = AudioContinuity()
    for index in 0..<5 {
      let next = frame(at: Double(index) * 0.1, seconds: 0.1)
      let out = continuity.frames(for: next)
      XCTAssertEqual(out.count, 1)
      XCTAssertEqual(out.first?.samples, next.samples)
    }
  }

  /// An ad with no sound: two seconds of nothing in the timestamps.
  func testAGapIsPlayedAsSilence() throws {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.1))
    let after = frame(at: 2.1, seconds: 0.1)
    let out = continuity.frames(for: after)
    let silence = out.dropLast()
    XCTAssertEqual(out.last?.samples, after.samples)
    XCTAssertEqual(seconds(Array(silence)), 2.0, accuracy: 0.001)
    XCTAssertEqual(silence.first?.presentationTime.seconds ?? -1, 0.1, accuracy: 1e-6)
    XCTAssertTrue(silence.allSatisfy { $0.samples.allSatisfy { $0 == 0 } })
    XCTAssertTrue(silence.allSatisfy { $0.channelCount == 2 && $0.sampleRate == 1000 })
    // One after another, none longer than a chunk.
    var clock = 0.1
    for piece in silence {
      XCTAssertEqual(piece.presentationTime.seconds, clock, accuracy: 1e-6)
      XCTAssertLessThanOrEqual(Double(piece.frameCount) / piece.sampleRate, AudioContinuity.silenceChunk)
      clock += Double(piece.frameCount) / piece.sampleRate
    }
  }

  func testTimestampRoundingIsLeftAlone() {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.1))
    XCTAssertEqual(continuity.frames(for: frame(at: 0.105, seconds: 0.1)).count, 1)
    XCTAssertEqual(continuity.frames(for: frame(at: 0.198, seconds: 0.1)).count, 1)
  }

  /// A container that keeps milliseconds — Matroska — rounds the start of
  /// every 1024-sample AAC frame (21.33 ms at 48 kHz) to 21 or 22 ms. Handed
  /// on so, the frames overlapped by 16 samples twice and left 32 out once,
  /// over and over: an output that places sound by its timestamps, as the
  /// system's renderer does, buzzed with it. Within rounding, each frame is
  /// set where the last one ended, to the sample.
  func testRoundedTimestampsAreSetBackToBack() {
    var continuity = AudioContinuity()
    var starts: [CMTime] = []
    for index in 0..<12 {
      let start = (Double(index) * 1024 / 48).rounded() / 1000
      let frame = AudioFrame(
        presentationTime: CMTime(seconds: start, preferredTimescale: 1_000_000), sampleRate: 48_000,
        channelCount: 1, frameCount: 1024, samples: [Float](repeating: 0.5, count: 1024))
      starts += continuity.frames(for: frame).map(\.presentationTime)
    }
    XCTAssertEqual(starts.count, 12)
    for index in 1..<starts.count {
      let step = CMTimeSubtract(starts[index], starts[index - 1]).seconds * 48_000
      XCTAssertEqual(step, 1024, accuracy: 1e-6, "frame \(index)")
    }
  }

  /// A codec that packs a varying number of blocks to a packet, labelled by
  /// the packet: the labels wander within some 23 ms around sound that is in
  /// fact continuous. Whichever label the sound is first placed by, every
  /// frame goes on where the last one ended; nothing is put in or cut out.
  func testTimestampsWanderingAroundContinuousSoundAreLeftAlone() {
    let wander = [-0.012, -0.021, -0.002, -0.017, 0, -0.023, -0.008, -0.015, -0.019, -0.004]
    for first in [-0.023, 0] {
      var continuity = AudioContinuity()
      for index in 0..<40 {
        let label = index == 0 ? first : wander[index % wander.count]
        let next = frame(at: 1 + Double(index) * 0.1 + label, seconds: 0.1)
        let out = continuity.frames(for: next)
        XCTAssertEqual(out.count, 1, "frame \(index)")
        XCTAssertEqual(out.first?.samples, next.samples, "frame \(index)")
        XCTAssertEqual(out.first?.presentationTime.seconds ?? -1, 1 + first + Double(index) * 0.1,
                       accuracy: 1e-6, "frame \(index)")
      }
    }
  }

  /// Sound early is noticed sooner than sound late: 100 ms early is set
  /// right at once, 100 ms late left as it is.
  func testSoundEarlyIsSetRightSoonerThanSoundLate() {
    var early = AudioContinuity()
    _ = early.frames(for: frame(at: 0, seconds: 0.2))
    let afterGap = early.frames(for: frame(at: 0.3, seconds: 0.2))
    XCTAssertEqual(seconds(Array(afterGap.dropLast())), 0.1, accuracy: 0.001)
    XCTAssertEqual(afterGap.last?.presentationTime.seconds ?? -1, 0.3, accuracy: 1e-6)

    var late = AudioContinuity()
    _ = late.frames(for: frame(at: 0, seconds: 0.2))
    let overlapping = frame(at: 0.1, seconds: 0.2)
    let out = late.frames(for: overlapping)
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(out.first?.samples, overlapping.samples)
    XCTAssertEqual(out.first?.presentationTime.seconds ?? -1, 0.2, accuracy: 1e-6)
  }

  /// A splice that sets every timestamp after it 60 ms later: more than goes
  /// unnoticed, less than is set right at once. The frames go on as they are
  /// until the offset has lasted, then silence takes it up, once.
  func testAnEarlyOffsetThatLastsIsSetRightOnce() {
    var continuity = AudioContinuity()
    var filled: [Int] = []
    for index in 0..<10 {
      let offset = index < 3 ? 0 : 0.06
      let out = continuity.frames(for: frame(at: Double(index) * 0.1 + offset, seconds: 0.1))
      if out.count > 1 {
        filled.append(index)
        XCTAssertEqual(seconds(Array(out.dropLast())), 0.06, accuracy: 0.001)
      }
      let settled = index >= 2 + AudioContinuity.lastingFrames
      XCTAssertEqual(out.last?.presentationTime.seconds ?? -1, Double(index) * 0.1 + (settled ? 0.06 : 0),
                     accuracy: 1e-6, "frame \(index)")
    }
    XCTAssertEqual(filled, [2 + AudioContinuity.lastingFrames])
  }

  /// Every timestamp after a splice 150 ms earlier: the frames go on as they
  /// are until the offset has lasted, then the part already played is cut,
  /// once.
  func testALateOffsetThatLastsIsSetRightOnce() {
    var continuity = AudioContinuity()
    var cut: [Int] = []
    for index in 0..<10 {
      let offset = index < 3 ? 0 : -0.15
      let out = continuity.frames(for: frame(at: Double(index) * 0.2 + offset, seconds: 0.2))
      XCTAssertEqual(out.count, 1, "frame \(index)")
      if out.first?.frameCount != 200 {
        cut.append(index)
        XCTAssertEqual(out.first?.frameCount, 50)
      }
    }
    XCTAssertEqual(cut, [2 + AudioContinuity.lastingFrames])
  }

  /// An offset that does not stay on one side is wandering, however far.
  func testAnOffsetThatComesAndGoesIsLeftAlone() {
    let offsets = [0, 0.06, 0.06, -0.15, -0.15, 0.06, 0, 0.06, 0.06, -0.15, -0.15, 0]
    var continuity = AudioContinuity()
    for (index, offset) in offsets.enumerated() {
      let out = continuity.frames(for: frame(at: Double(index) * 0.2 + offset, seconds: 0.2))
      XCTAssertEqual(out.count, 1, "frame \(index)")
      XCTAssertEqual(out.first?.frameCount, 200, "frame \(index)")
      XCTAssertEqual(out.first?.presentationTime.seconds ?? -1, Double(index) * 0.2, accuracy: 1e-6, "frame \(index)")
    }
  }

  /// Where the last frame ended, counted in seconds, falls a hair short of
  /// a sample now and then: the next frame is still stamped on the sample
  /// it starts on, not the one before.
  func testFramesBackToBackAreStampedOnTheirSample() {
    var continuity = AudioContinuity()
    for index in 0..<500 {
      let frame = AudioFrame(
        presentationTime: CMTime(value: CMTimeValue(index * 2048), timescale: 44_100), sampleRate: 44_100,
        channelCount: 1, frameCount: 2048, samples: [Float](repeating: 0.5, count: 2048))
      let stamp = CMTimeConvertScale(
        continuity.frames(for: frame)[0].presentationTime, timescale: 44_100, method: .quickTime)
      XCTAssertEqual(stamp.value, CMTimeValue(index * 2048), "frame \(index)")
    }
  }

  /// Timestamps that step a little further than the samples between them
  /// part from what has been played by a little each time; once that adds
  /// up past what goes unnoticed, it is taken up.
  func testDriftIsTakenUp() {
    var continuity = AudioContinuity()
    var handed = 0.0
    for index in 0..<30 {
      let out = continuity.frames(for: frame(at: Double(index) * 0.103, seconds: 0.1))
      handed += seconds(out)
    }
    XCTAssertGreaterThan(handed, 3.0 + AudioContinuity.unnoticed.early, "silence was put in")
    XCTAssertEqual(handed, 29 * 0.103 + 0.1, accuracy: AudioContinuity.unnoticed.early)
  }

  /// A run after a splice starting further before the last one ended than
  /// timestamps wander: the part already played is cut from it at once,
  /// channel by channel.
  func testAnOverlapIsCutFromTheLaterSound() throws {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.5))
    let out = continuity.frames(for: frame(at: 0.25, seconds: 0.5))
    let cut = try XCTUnwrap(out.first)
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(cut.presentationTime.seconds, 0.5, accuracy: 1e-6)
    XCTAssertEqual(cut.frameCount, 250)
    XCTAssertEqual(Array(cut.samples.prefix(2)), [250, 251])
    XCTAssertEqual(cut.samples[250], 1250, "the second channel cut as the first")
  }

  func testSoundWhollyPlayedAlreadyIsLeftOut() {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.5))
    XCTAssertTrue(continuity.frames(for: frame(at: 0.1, seconds: 0.2)).isEmpty)
    XCTAssertEqual(continuity.frames(for: frame(at: 0.5, seconds: 0.1)).count, 1)
  }

  /// An overlap longer than a frame: once one frame is left out whole, what
  /// is left of the overlap is cut from the next too, small as it is by then.
  func testAnOverlapLongerThanAFrameIsCutToItsEnd() throws {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.5))
    XCTAssertTrue(continuity.frames(for: frame(at: 0.1, seconds: 0.3)).isEmpty)
    let cut = try XCTUnwrap(continuity.frames(for: frame(at: 0.4, seconds: 0.3)).first)
    XCTAssertEqual(cut.presentationTime.seconds, 0.5, accuracy: 1e-6)
    XCTAssertEqual(cut.frameCount, 200)
    XCTAssertEqual(Array(cut.samples.prefix(2)), [100, 101])
  }

  /// Too long to be a gap in the sound: a timestamp gone wrong, followed
  /// rather than filled.
  func testALeapTooLongToFillIsFollowed() {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.1))
    let leap = AudioContinuity.longestGap + 10
    XCTAssertEqual(continuity.frames(for: frame(at: leap, seconds: 0.1)).count, 1)
    XCTAssertEqual(continuity.frames(for: frame(at: leap + 0.1, seconds: 0.1)).count, 1)
  }

  func testResetForgetsWhereTheSoundWas() {
    var continuity = AudioContinuity()
    _ = continuity.frames(for: frame(at: 0, seconds: 0.1))
    continuity.reset()
    XCTAssertEqual(continuity.frames(for: frame(at: 5, seconds: 0.1)).count, 1)
  }
}
