import AVFoundation
import CoreMedia
import XCTest
@testable import UmbelCore

/// Multichannel output. Most films carry 5.1; a format the engine refuses
/// means no sound at all, not merely less of it.
final class EngineAudioFormatTests: XCTestCase {
  /// Every common channel count gets a format. Above two, a plain channel
  /// count is not enough for AVAudioFormat — it needs to know which speaker
  /// each channel is for.
  func testCommonChannelCountsHaveAFormat() {
    for count in 1...8 {
      let format = EngineAudioOutput.makeFormat(sampleRate: 48_000, channelCount: count)
      XCTAssertEqual(format?.channelCount, AVAudioChannelCount(count), "\(count) channels")
    }
  }

  /// The layout has to name the channels in the order the decoder delivers
  /// them — FFmpeg's default order, which is the WAVE channel-mask order:
  /// for 5.1, left, right, centre, LFE, then the surround pair.
  func testFiveOneIsLabelledInDecoderOrder() throws {
    let format = try XCTUnwrap(EngineAudioOutput.makeFormat(sampleRate: 48_000, channelCount: 6))
    let layout = try XCTUnwrap(format.channelLayout)
    let labels = channelLabels(layout)
    XCTAssertEqual(labels, [
      kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
      kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    ])
  }

  /// The labels CoreAudio reads out of a bitmap layout, in channel order.
  private func channelLabels(_ layout: AVAudioChannelLayout) -> [AudioChannelLabel] {
    guard layout.layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap else {
      return []
    }
    var bitmap = layout.layout.pointee.mChannelBitmap.rawValue
    var size: UInt32 = 0
    let specifierSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioFormatGetPropertyInfo(
      kAudioFormatProperty_ChannelLayoutForBitmap, specifierSize, &bitmap, &size) == noErr else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    guard AudioFormatGetProperty(
      kAudioFormatProperty_ChannelLayoutForBitmap, specifierSize, &bitmap, &size, raw) == noErr else {
      return []
    }
    let expanded = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    let count = Int(expanded.pointee.mNumberChannelDescriptions)
    return withUnsafePointer(to: &expanded.pointee.mChannelDescriptions) { first in
      first.withMemoryRebound(to: AudioChannelDescription.self, capacity: count) { descriptions in
        (0..<count).map { descriptions[$0].mChannelLabel }
      }
    }
  }

  /// End to end on a real device: a 5.1 stream prepares, starts and takes
  /// frames. The system mixer folds it down to whatever the device has.
  func testFiveOneStreamPlaysThroughTheEngine() async throws {
    let output = EngineAudioOutput()
    do {
      try await output.prepare(sampleRate: 48_000, channelCount: 6)
      try await output.start()
    } catch let error as UmbelError {
      if case .audioOutputUnavailable(let reason) = error, reason.contains("channels") { throw error }
      throw XCTSkip("no audio output device here: \(error)")
    }
    addTeardownBlock { await output.stop() }
    try await output.enqueue(
      AudioFrame(
        presentationTime: .zero, sampleRate: 48_000, channelCount: 6, frameCount: 1024,
        samples: [Float](repeating: 0, count: 6 * 1024)))
  }
}
