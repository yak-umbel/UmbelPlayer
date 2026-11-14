import AudioToolbox
import CoreMedia
import UmbelFFmpegSupport
import XCTest
@testable import UmbelCore

/// Decoded sound as the system's renderer plays it: 32-bit float, the
/// channels interleaved, each frame with its own format. Given a buffer per
/// channel, the renderer took the samples, said it was rendering and played
/// nothing at all.
final class PCMSampleBufferTests: XCTestCase {
  private func frame(channels: Int, count: Int = 480, at seconds: Double = 1.5) -> AudioFrame {
    var samples: [Float] = []
    for channel in 0..<channels { samples += (0..<count).map { Float(channel) + Float($0) / 10_000 } }
    return AudioFrame(
      presentationTime: CMTime(seconds: seconds, preferredTimescale: 48_000), sampleRate: 48_000,
      channelCount: channels, frameCount: count, samples: samples)
  }

  private func description(_ format: CMAudioFormatDescription) -> AudioStreamBasicDescription {
    CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
  }

  private func layout(_ format: CMAudioFormatDescription) -> AudioChannelLayout {
    var size = 0
    return CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size)!.pointee
  }

  func testTheFormatIsInterleavedFloat() throws {
    let asbd = description(try PCMSampleBuffer.format(sampleRate: 44_100, channelCount: 2))
    XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
    XCTAssertEqual(asbd.mSampleRate, 44_100)
    XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    XCTAssertEqual(asbd.mBitsPerChannel, 32)
    XCTAssertEqual(asbd.mBytesPerFrame, 8, "a sample of every channel")
    XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, 0)
    XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
  }

  /// Mono and stereo by name; more by FFmpeg's default mask as a channel
  /// bitmap, in the order the decoder hands the channels on.
  func testSpeakersAreNamed() throws {
    XCTAssertEqual(layout(try PCMSampleBuffer.format(sampleRate: 48_000, channelCount: 1)).mChannelLayoutTag,
                   kAudioChannelLayoutTag_Mono)
    XCTAssertEqual(layout(try PCMSampleBuffer.format(sampleRate: 48_000, channelCount: 2)).mChannelLayoutTag,
                   kAudioChannelLayoutTag_Stereo)
    for channels in [6, 8] {
      let named = layout(try PCMSampleBuffer.format(sampleRate: 48_000, channelCount: channels))
      XCTAssertEqual(named.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelBitmap)
      let mask = try XCTUnwrap(FFmpegResampler.defaultChannelMask(channelCount: channels))
      XCTAssertEqual(UInt64(named.mChannelBitmap.rawValue), mask)
    }
  }

  func testACountWithoutSpeakersIsRefused() {
    XCTAssertThrowsError(try PCMSampleBuffer.format(sampleRate: 48_000, channelCount: 40))
  }

  /// The frame's time, length and every channel's samples, interleaved.
  func testASampleCarriesTheFrame() throws {
    let source = frame(channels: 3)
    let sample = try PCMSampleBuffer.make(source)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), source.presentationTime)
    XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 480)
    XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 480 * 3 * 4)
    var block: CMBlockBuffer?
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
      bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 1), blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
    XCTAssertEqual(status, noErr)
    XCTAssertEqual(list.count, 1)
    let values = Array(UnsafeBufferPointer(
      start: list[0].mData!.assumingMemoryBound(to: Float.self), count: 480 * 3))
    for index in [0, 1, 239, 479] {
      for channel in 0..<3 {
        XCTAssertEqual(values[index * 3 + channel], source.samples[channel * 480 + index])
      }
    }
  }

  /// Every channel in its own place: 5.1's six, interleaved, as they come.
  func testSixChannelsKeepTheirOrder() throws {
    let source = frame(channels: 6, count: 4)
    let sample = try PCMSampleBuffer.make(source)
    var block: CMBlockBuffer?
    let list = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(list.unsafeMutablePointer) }
    XCTAssertEqual(CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sample, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
      bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 1), blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block), noErr)
    let values = Array(UnsafeBufferPointer(start: list[0].mData!.assumingMemoryBound(to: Float.self), count: 24))
    XCTAssertEqual(Array(values[0..<6]).map { Int($0) }, [0, 1, 2, 3, 4, 5])
  }

  /// After a switch of track, a frame decoded for the old one still plays
  /// right: each sample says its own format.
  func testFramesOfDifferentFormatsCarryTheirOwn() throws {
    let stereo = try PCMSampleBuffer.make(frame(channels: 2))
    let surround = try PCMSampleBuffer.make(frame(channels: 6))
    XCTAssertEqual(description(CMSampleBufferGetFormatDescription(stereo)!).mChannelsPerFrame, 2)
    XCTAssertEqual(description(CMSampleBufferGetFormatDescription(surround)!).mChannelsPerFrame, 6)
  }
}
