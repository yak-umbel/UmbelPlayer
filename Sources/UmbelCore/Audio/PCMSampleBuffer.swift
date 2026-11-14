import AudioToolbox
import CoreMedia
import UmbelFFmpegSupport

/// Decoded sound as the system's sample buffer audio renderer plays it:
/// 32-bit float, the channels interleaved. `AudioFrame` holds a buffer per
/// channel, and given that the renderer took the samples, said it was
/// rendering, and played nothing at all: it is interleaved on the way.
///
/// Each frame goes in its own format. A frame decoded for the track before
/// a switch still plays right: the renderer follows the format sample by
/// sample, where the audio engine had to be reconnected.
internal enum PCMSampleBuffer {
  /// Above two channels the speakers are named by FFmpeg's default mask for
  /// the count, as a channel bitmap: FFmpeg's masks and CoreAudio's bitmaps
  /// share the WAVE bit order, and the decoder hands the channels on in it.
  /// Heard right on the Mac and the iPad alike. CoreAudio's bitmap stops at
  /// the top back pair, bit 17.
  static func format(sampleRate: Double, channelCount: Int) throws -> CMAudioFormatDescription {
    guard sampleRate > 0, channelCount > 0 else { throw failure("\(sampleRate) Hz, \(channelCount) channels") }
    var layout = AudioChannelLayout()
    switch channelCount {
    case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    default:
      guard let mask = FFmpegResampler.defaultChannelMask(channelCount: channelCount),
            mask < 1 << 18 else { throw failure("no speakers for \(channelCount) channels") }
      layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
      layout.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(mask))
    }
    let bytesPerFrame = UInt32(channelCount * MemoryLayout<Float>.size)
    var description = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
      mChannelsPerFrame: UInt32(channelCount), mBitsPerChannel: 32, mReserved: 0)
    var made: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &description,
      layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &made)
    guard status == noErr, let made else { throw failure("format \(status)") }
    return made
  }

  /// A frame as a sample stamped with its presentation time.
  static func make(_ frame: AudioFrame) throws -> CMSampleBuffer {
    let channels = frame.channelCount, count = frame.frameCount
    guard count > 0, frame.samples.count == count * channels else {
      throw failure("a frame whose samples do not fill its channels")
    }
    let format = try format(sampleRate: frame.sampleRate, channelCount: channels)
    let size = count * channels * MemoryLayout<Float>.size
    var made: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &made)
    guard status == noErr, let block = made else { throw failure("memory \(status)") }
    var pointer: UnsafeMutablePointer<CChar>?
    status = CMBlockBufferGetDataPointer(
      block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
    guard status == noErr, let pointer else { throw failure("memory \(status)") }
    pointer.withMemoryRebound(to: Float.self, capacity: count * channels) { out in
      frame.samples.withUnsafeBufferPointer { planar in
        for channel in 0..<channels {
          let from = channel * count
          for index in 0..<count { out[index * channels + channel] = planar[from + index] }
        }
      }
    }
    var sample: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
      sampleCount: count, presentationTimeStamp: frame.presentationTime,
      packetDescriptions: nil, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw failure("sample \(status)") }
    return sample
  }

  private static func failure(_ what: String) -> UmbelError {
    .audioOutputUnavailable(reason: "cannot hand sound to the system: \(what)")
  }
}
