import AVFoundation
import XCTest
@testable import UmbelCore

/// How the system's renderer is set up.
final class SystemAudioRendererTests: XCTestCase {
  private func renderer() -> AVSampleBufferAudioRenderer {
    SystemAudioRenderer(volume: 0, onDiscarded: {}).queued.renderer as! AVSampleBufferAudioRenderer
  }

  /// Stereo and mono are allowed to be spatialized too, not only
  /// multichannel sound: whether they are is the listener's call, where the
  /// system offers it.
  func testStereoMayBeSpatializedIfTheListenerWishes() {
    XCTAssertEqual(renderer().allowedAudioSpatializationFormats, .monoStereoAndMultichannel)
  }

  /// Other rates keep the pitch.
  func testThePitchIsKept() {
    XCTAssertEqual(renderer().audioTimePitchAlgorithm, .spectral)
  }
}
