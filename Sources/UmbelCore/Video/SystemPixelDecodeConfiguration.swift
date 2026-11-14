import CoreMedia
import CoreVideo
import Foundation
import UmbelFFmpegSupport

/// The source configuration admitted when a system pixel session starts.
/// New setup bytes or picture sizes may retain it; a different metadata
/// format or pixel representation must go through route selection again.
internal struct SystemPixelDecodeConfiguration {
  private let record: FFmpegDOVIConfiguration

  var isP5: Bool { record.profile == 5 && record.compatibility == 0 }
  var outputPixelFormat: OSType {
    isP5 ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }

  init(record: FFmpegDOVIConfiguration, pixels: VideoPixelDescription?) throws {
    try Self.requireSystemRepresentation(record)
    guard (record.profile == 5 && record.compatibility == 0
           || record.profile == 8 && [1, 4].contains(record.compatibility)),
          record.versionMajor == 1, record.versionMinor == 0,
          record.metadataCompression == 0, record.hasRPU, !record.hasEnhancementLayer,
          Self.supports(pixels) else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel route unverified for source configuration")
    }
    self.record = record
  }

  func validate(record changed: FFmpegDOVIConfiguration?, pixels: VideoPixelDescription?) throws {
    if let changed { try Self.requireSystemRepresentation(changed) }
    guard changed == record, Self.supports(pixels) else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel route unverified for changed configuration")
    }
  }

  func validate(parameters: FFmpegCodecParameters) throws {
    try validate(record: parameters.dovi,
      pixels: parameters.videoFormat.map(VideoPixelDescription.init(ffmpeg:)))
    // P5's components are not a conventional YCbCr base layer. Keep their
    // full range and let the system interpret the original frame metadata.
    if isP5 {
      guard [0, 2].contains(parameters.colorRange),
            [0, 2].contains(parameters.colorTransfer),
            [0, 2].contains(parameters.colorPrimaries), parameters.colorMatrix == 2 else {
        throw UmbelError.videoRenderUnavailable(reason: "system P5 pixels require the original full-range signal")
      }
      return
    }
    let transfer: Int32 = record.compatibility == 4 ? 18 : 16
    guard [0, 2, transfer].contains(parameters.colorTransfer),
          [0, 2, 9].contains(parameters.colorPrimaries),
          [2, 9].contains(parameters.colorMatrix),
          [0, 1].contains(parameters.colorRange) else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel route conflicts with source color configuration")
    }
  }

  /// Parameter sets can change without a new container parameter object.
  /// Check the description actually submitted before requesting fixed-format
  /// buffers, so a system conversion cannot conceal a loss of source detail.
  func validate(description: CMVideoFormatDescription) throws {
    guard let atoms = CMFormatDescriptionGetExtension(description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
          let hvcC = atoms["hvcC"] as? Data, hvcC.count >= 23 else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel format has no known HEVC configuration")
    }
    // HEVCDecoderConfigurationRecord: configurationVersion, chromaFormat,
    // bitDepthLumaMinus8 and bitDepthChromaMinus8 in the fixed header.
    let header = [UInt8](hvcC.prefix(23))
    guard header[0] == 1, header[16] & 0x03 == 1,
          header[17] & 0x07 == 2, header[18] & 0x07 == 2 else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel format cannot preserve source precision and sampling")
    }
    if isP5 {
      if let range = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo),
         !CFEqual(range, kCFBooleanTrue) {
        throw UmbelError.videoRenderUnavailable(reason: "system P5 format must preserve full range")
      }
      if let depth = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent),
         !CFEqual(depth, NSNumber(value: 10)) {
        throw UmbelError.videoRenderUnavailable(reason: "system P5 format must preserve ten-bit components")
      }
      return
    }
    let transfer: CFString = record.compatibility == 4
      ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
      : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
    let expected: [(CFString, CFTypeRef)] = [
      (kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020),
      (kCMFormatDescriptionExtension_TransferFunction, transfer),
      (kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020),
      (kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanFalse),
      (kCMFormatDescriptionExtension_BitsPerComponent, NSNumber(value: 10)),
    ]
    for (key, required) in expected {
      if let declared = CMFormatDescriptionGetExtension(description, extensionKey: key),
         !CFEqual(declared, required) {
        throw UmbelError.videoRenderUnavailable(reason: "system pixel format conflicts with source color configuration")
      }
    }
  }

  /// The output request must preserve every source component's precision
  /// and sampling. Unknown formats are not assumed to be 10-bit 4:2:0.
  static func supports(_ pixels: VideoPixelDescription?) -> Bool {
    guard let pixels else { return false }
    return pixels.effectiveBits == 10 && pixels.componentBits == [10, 10, 10]
      && pixels.chromaSubsampling == "4:2:0" && !pixels.isRGB && !pixels.isFloatingPoint
  }

  private static func requireSystemRepresentation(_ record: FFmpegDOVIConfiguration) throws {
    guard record.hasBaseLayer,
          record.profile == 5 && record.compatibility == 0 || [1, 2, 4, 6].contains(record.compatibility) else {
      throw UmbelError.unsupportedDynamicHDR("configuration has no verified compatible base layer")
    }
  }
}
