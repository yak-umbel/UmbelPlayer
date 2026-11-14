import CoreVideo

extension FFmpegVideoFrame {
  public init(
    pixelBuffer: CVPixelBuffer, width: Int32, height: Int32, pts: Int64,
    timeBaseNum: Int32, timeBaseDen: Int32, colorspace: Int32, colorRange: Int32,
    colorTransfer: Int32 = 2, colorPrimaries: Int32 = 2, hdr: FFmpegHDRMetadata? = nil,
    sampleAspectNum: Int32 = 0, sampleAspectDen: Int32 = 1, rotation: Int32 = 0,
    isInterlaced: Bool = false, topFieldFirst: Bool = false, duration: Int64 = 0,
    frameRateNum: Int32 = 0, frameRateDen: Int32 = 1, wasHardwareDecoded: Bool
  ) {
    self.init(pixelBuffer: pixelBuffer, width: width, height: height, pts: pts,
      timeBaseNum: timeBaseNum, timeBaseDen: timeBaseDen, colorspace: colorspace, colorRange: colorRange,
      colorTransfer: colorTransfer, colorPrimaries: colorPrimaries, hdr: hdr,
      sampleAspectNum: sampleAspectNum, sampleAspectDen: sampleAspectDen, rotation: rotation,
      isInterlaced: isInterlaced, topFieldFirst: topFieldFirst, duration: duration,
      frameRateNum: frameRateNum, frameRateDen: frameRateDen, wasHardwareDecoded: wasHardwareDecoded,
      sourceFormat: nil)
  }
}

extension FFmpegStreamInfo {
  public init(
    index: Int32, mediaType: FFmpegMediaType, codecName: String, language: String?, title: String?,
    isDefault: Bool, isForced: Bool, width: Int32, height: Int32,
    frameRateNum: Int32, frameRateDen: Int32, channelCount: Int32, sampleRate: Int32,
    sampleAspectNum: Int32 = 0, sampleAspectDen: Int32 = 1, rotation: Int32 = 0,
    colorTransfer: Int32 = 2, dovi: FFmpegDOVIConfiguration? = nil, hasDecoder: Bool = true
  ) {
    self.init(index: index, mediaType: mediaType, codecName: codecName, language: language, title: title,
      isDefault: isDefault, isForced: isForced, width: width, height: height,
      frameRateNum: frameRateNum, frameRateDen: frameRateDen, channelCount: channelCount, sampleRate: sampleRate,
      sampleAspectNum: sampleAspectNum, sampleAspectDen: sampleAspectDen, rotation: rotation,
      colorTransfer: colorTransfer, dovi: dovi, hasDecoder: hasDecoder, videoFormat: nil)
  }
}
