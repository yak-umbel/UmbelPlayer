import CoreMedia
import CoreVideo

/// Wraps original or composed pixels with their format and presentation time.
internal enum VideoSampleBuffer {
  static func make(
    of image: CVPixelBuffer, at time: CMTime, immediately: Bool
  ) throws -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard let format,
          CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
          let sample else {
      throw UmbelError.videoRenderUnavailable(reason: "cannot wrap the picture as a sample")
    }
    if immediately,
       let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
       CFArrayGetCount(attachments) > 0 {
      let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }
}
