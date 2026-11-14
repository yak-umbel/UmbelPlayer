import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// A real output needs audio hardware. Without a device, skipped with the
/// reason given; nothing passes silently.
final class EngineAudioOutputTests: XCTestCase {
  private func startedOutputOrSkip() async throws -> EngineAudioOutput {
    let output = EngineAudioOutput()
    do {
      try await output.prepare(sampleRate: 48_000, channelCount: 2)
      try await output.start()
    } catch {
      throw XCTSkip("no audio output device here: \(error)")
    }
    return output
  }

  /// With the engine running but no frame yet scheduled, there is no anchor.
  ///
  /// What one would do: after a seek to 05:00 nothing is scheduled while the
  /// discard window lasts, and an anchor near zero reported then would drag
  /// the clock back to the start, sound and picture all wrong.
  func testNoAnchorBeforeFirstFrame() async throws {
    let output = try await startedOutputOrSkip()
    addTeardownBlock { await output.stop() }

    let anchor = await output.currentAnchor
    XCTAssertNil(anchor, "no anchor before the first frame is scheduled")
  }

  /// Reading the anchor never brings the process down, whatever state the
  /// device is in. An engine that started over a device that never runs
  /// reports a render time with nothing valid in it, and asking the player
  /// to convert that raises an exception Swift cannot catch — met on a Mac
  /// whose audio had stopped cycling, where playback then ended in a crash.
  func testTheAnchorIsSafeToReadWhateverTheDevice() async throws {
    let output = EngineAudioOutput()
    addTeardownBlock { await output.stop() }
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    try? await output.start()
    try? await output.enqueue(
      AudioFrame(
        presentationTime: CMTime(seconds: 3, preferredTimescale: 600),
        sampleRate: 48_000, channelCount: 2, frameCount: 1024,
        samples: [Float](repeating: 0, count: 2048)))
    _ = await output.currentAnchor
  }

  /// Speed without a change of pitch: the sound goes through the system's
  /// time-pitch unit, left out of the way at the normal rate, and kept
  /// through a change of format — a track switch.
  func testTheRateGoesToTheTimePitchUnit() async throws {
    let output = EngineAudioOutput()
    addTeardownBlock { await output.stop() }
    try await output.prepare(sampleRate: 48_000, channelCount: 2)
    var unit = await output.timePitchState
    XCTAssertEqual(unit.rate, 1)
    XCTAssertTrue(unit.bypassed, "at the normal rate the sound is as before, sample for sample")
    await output.setRate(1.5)
    unit = await output.timePitchState
    XCTAssertEqual(unit.rate, 1.5)
    XCTAssertFalse(unit.bypassed)
    try await output.prepare(sampleRate: 44_100, channelCount: 6)
    unit = await output.timePitchState
    XCTAssertEqual(unit.rate, 1.5)
    XCTAssertTrue(unit.isInTheChain)
    await output.setRate(1)
    unit = await output.timePitchState
    XCTAssertTrue(unit.bypassed, "back at the normal rate, out of the way again")
  }

  /// A pause — every seek makes one — leaves the engine running, so sound
  /// comes back at once: starting a paused engine again took up to a
  /// quarter of a second.
  func testPauseLeavesTheEngineRunning() async throws {
    let output = try await startedOutputOrSkip()
    addTeardownBlock { await output.stop() }
    await output.pause()
    let running = await output.isEngineRunning
    XCTAssertTrue(running)
  }

  /// After `stop()` there is again no first frame, so again no anchor. A seek
  /// relies on stop to clear the last stretch's anchor.
  func testStopClearsAnchor() async throws {
    let output = try await startedOutputOrSkip()
    addTeardownBlock { await output.stop() }

    try await output.enqueue(
      AudioFrame(
        presentationTime: CMTime(seconds: 300, preferredTimescale: 600),
        sampleRate: 48_000, channelCount: 2, frameCount: 1024,
        samples: [Float](repeating: 0, count: 2048)))
    await output.stop()

    let anchor = await output.currentAnchor
    XCTAssertNil(anchor, "no anchor from the last stretch after stop")
  }

  /// Prepared again in another format, the player reconnects in the new one.
  ///
  /// The connection's format is checked, not "scheduling does not throw": a
  /// mismatched `scheduleBuffer` raises an Objective-C exception that takes
  /// the whole test process down rather than failing one test — no use.
  func testPrepareReconnectsWhenFormatChanges() async throws {
    let output = try await startedOutputOrSkip()
    addTeardownBlock { await output.stop() }

    let before = await output.connectedChannelCount
    XCTAssertEqual(before, 2, "precondition: connected in stereo to begin with")

    try await output.prepare(sampleRate: 48_000, channelCount: 1)
    let after = await output.connectedChannelCount
    XCTAssertEqual(after, 1, "a new format reconnects; otherwise the node keeps the old one")
  }

  /// A format change while an enqueue waits for a slot: woken, it must not
  /// hand the player a buffer in the old format.
  ///
  /// The crash an audio track switch ran into on a real device:
  /// `AVAudioPlayerNode` checks formats itself and raises an Objective-C
  /// exception on a mismatch, ending the process (required condition is
  /// false: _outputFormat.channelCount == buffer.format.channelCount). **The
  /// test double does not check formats, so only the real output catches
  /// it.** Every sample is zero; the test makes no sound.
  func testChangingFormatWhileEnqueueIsWaitingDoesNotCrash() async throws {
    let output = try await startedOutputOrSkip()   // stereo
    addTeardownBlock { await output.stop() }

    func silence(channels: Int) -> AudioFrame {
      AudioFrame(
        presentationTime: .zero, sampleRate: 48_000, channelCount: channels,
        frameCount: 4_800, samples: [Float](repeating: 0, count: 4_800 * channels))
    }

    // Fill the slots (8 of them), and the next enqueue waits.
    for _ in 0..<8 { try await output.enqueue(silence(channels: 2)) }

    let blocked = Task { try? await output.enqueue(silence(channels: 2)) }
    try await Task.sleep(nanoseconds: 100_000_000)

    // Mono while it waits: prepare reconnects the player and lets waiters go.
    try await output.prepare(sampleRate: 48_000, channelCount: 1)
    _ = await blocked.value

    // Getting here alive is passing — a crash would take the whole process.
    let channels = await output.connectedChannelCount
    XCTAssertEqual(channels, 1)
  }

  /// No device needed: the mixer holds its level before the engine runs.
  func testTheMixerTakesTheLevel() async {
    let output = EngineAudioOutput()
    await output.setVolume(0.3, muted: false)
    var level = await output.mixerVolume
    XCTAssertEqual(level, 0.3, accuracy: 0.0001)
    await output.setVolume(0.3, muted: true)
    level = await output.mixerVolume
    XCTAssertEqual(level, 0)
  }
}
