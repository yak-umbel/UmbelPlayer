import CoreMedia
import CoreVideo
import Foundation

/// A video frame: decoded, or — for pictures only the system can show — the
/// compressed sample the system decodes itself.
///
/// Hardware returns a system pixel buffer; software converts into a compatible
/// buffer while retaining supported depth and sampling. RGB stays RGB.
public struct VideoFrame: @unchecked Sendable {
  public enum Content: @unchecked Sendable {
    case pixels(CVPixelBuffer)
    /// A sample for the system's display layer: DV without a base layer of
    /// its own, whose colours only the system's processing gets right.
    case compressed(CMSampleBuffer)
  }

  public let presentationTime: CMTime
  public let content: Content
  public let width: Int
  public let height: Int
  public let color: VideoColorDescription
  /// The width of one pixel over its height as shown; 1 for square pixels.
  public let pixelAspectRatio: Double
  /// How far the picture is turned, clockwise, to be shown upright. `.none`
  /// for a frame the system shows as stored.
  public let rotation: UmbelVideoRotation
  /// False for a frame decoded but not shown: before a seek's target, sent
  /// on because the system decodes the frames after from it.
  public let isShown: Bool
  public internal(set) var sourcePixelDescription: VideoPixelDescription?
  internal var hasDynamicMetadata = false
  internal var dynamicMetadataInvalidated = false
  internal var conversionReason: String?
  public internal(set) var presentationRoute: UmbelVideoPresentationRoute = .metalPixels
  /// Raw location: 0 undeclared, 1 left, 2 center, 3 top-left, 4 top,
  /// 5 bottom-left, 6 bottom. The original declaration remains observable.
  public internal(set) var chromaLocationCode: Int32 = 0
  /// For an interlaced picture, which field comes first in time; nil for a
  /// progressive one. Set by the decoding engine, cleared once deinterlaced.
  internal var fieldOrder: FieldOrder?
  /// How long the frame shows; invalid when not known.
  internal var duration: CMTime = .invalid
  /// The frame rate the stream declares, in frames a second; nil when it
  /// declares none.
  internal var declaredFrameRate: Double?

  public init(
    presentationTime: CMTime,
    pixelBuffer: CVPixelBuffer,
    width: Int,
    height: Int,
    color: VideoColorDescription,
    pixelAspectRatio: Double = 1,
    rotation: UmbelVideoRotation = .none
  ) {
    self.presentationTime = presentationTime
    self.content = .pixels(pixelBuffer)
    self.width = width
    self.height = height
    self.color = color
    self.pixelAspectRatio = pixelAspectRatio
    self.rotation = rotation
    self.isShown = true
  }

  internal init(
    presentationTime: CMTime,
    compressed sample: CMSampleBuffer,
    width: Int,
    height: Int,
    color: VideoColorDescription,
    pixelAspectRatio: Double = 1,
    isShown: Bool
  ) {
    self.presentationTime = presentationTime
    self.content = .compressed(sample)
    self.presentationRoute = .systemCompressed
    self.width = width
    self.height = height
    self.color = color
    self.pixelAspectRatio = pixelAspectRatio
    self.rotation = .none
    self.isShown = isShown
  }

  /// The decoded pixels; nil for a frame the system decodes.
  public var pixelBuffer: CVPixelBuffer? {
    if case .pixels(let buffer) = content { return buffer }
    return nil
  }

  /// The compressed sample; nil for a decoded frame.
  public var compressedSample: CMSampleBuffer? {
    if case .compressed(let sample) = content { return sample }
    return nil
  }

  internal var effectiveBitDepth: Int? {
    pixelBuffer.map { VideoPixelDescription(cvFormat: CVPixelBufferGetPixelFormatType($0)).effectiveBits } ?? nil
  }
  internal var preferredWorkingBits: Int? {
    guard let description = pixelDescription else { return nil }
    return description.isFloatingPoint ? description.storageBits : description.effectiveBits
  }

  public var pixelDescription: VideoPixelDescription? {
    pixelBuffer.map { VideoPixelDescription(cvFormat: CVPixelBufferGetPixelFormatType($0)) }
  }

  /// The picture as shown: stored pixels, widened or narrowed to their shape,
  /// then turned.
  public var displaySize: CGSize {
    rotation.turned(CGSize(width: Double(width) * pixelAspectRatio, height: Double(height)))
  }

  /// The stored pixels as shown: turned, but not widened to the pixel shape.
  /// What subtitles are laid out against.
  internal var orientedPixelSize: CGSize {
    rotation.turned(CGSize(width: width, height: height))
  }
}

extension VideoFrame {
  /// Makes a biplanar buffer of one colour.
  ///
  /// For tests and offscreen checks: the caller gives the colour as YUV, so
  /// the RGB to expect can be worked out independently, and checks do not
  /// lean on the conversion under test.
  internal static func makeTestPixelBuffer(
    width: Int,
    height: Int,
    luma: UInt8,
    cb: UInt8,
    cr: UInt8
  ) -> CVPixelBuffer? {
    guard let buffer = makeBiplanarBuffer(width: width, height: height) else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
      let base = plane.assumingMemoryBound(to: UInt8.self)
      for row in 0..<rows {
        memset(base + row * bytesPerRow, Int32(luma), width)
      }
    }

    if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
      let base = plane.assumingMemoryBound(to: UInt8.self)
      for row in 0..<rows {
        let line = base + row * bytesPerRow
        // Interleaved: Cb, then Cr.
        for column in stride(from: 0, to: width, by: 2) {
          line[column] = cb
          line[column + 1] = cr
        }
      }
    }
    return buffer
  }

  /// The 10-bit kind, P010: each sample a 10-bit code in the top of 16 bits.
  internal static func makeTestP010PixelBuffer(
    width: Int, height: Int, luma: UInt16, cb: UInt16, cr: UInt16
  ) -> CVPixelBuffer? {
    guard let buffer = makeBiplanarBuffer(
      width: width, height: height, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for (plane, values) in [(0, [luma]), (1, [cb, cr])] {
      guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let samples = CVPixelBufferGetWidthOfPlane(buffer, plane) * values.count
      for row in 0..<rows {
        let line = (base + row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
        for index in 0..<samples { line[index] = values[index % values.count] << 6 }
      }
    }
    return buffer
  }

  fileprivate static func makeBiplanarBuffer(
    width: Int, height: Int,
    format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  ) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess else { return nil }
    return buffer
  }
}

/// Test patterns with a direction: a single colour cannot show which way
/// up a picture is.
internal enum SplitOrientation: Sendable {
  /// Bright above, dark below.
  case topBright
  /// Bright on the left, dark on the right.
  case leftBright
  /// Bright in the top-left quadrant only: where that corner ends up says
  /// which way the picture was turned.
  case topLeftBright
}

extension VideoFrame {
  /// Makes a biplanar buffer half bright, half dark, to check which way up
  /// rendering draws.
  internal static func makeSplitPixelBuffer(
    width: Int,
    height: Int,
    orientation: SplitOrientation
  ) -> CVPixelBuffer? {
    guard let buffer = makeBiplanarBuffer(width: width, height: height) else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    // Limited range: bright is 235, dark 16.
    if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
      let base = plane.assumingMemoryBound(to: UInt8.self)
      for row in 0..<rows {
        let line = base + row * bytesPerRow
        switch orientation {
        case .topBright:
          memset(line, row < rows / 2 ? 235 : 16, width)
        case .leftBright:
          memset(line, 235, width / 2)
          memset(line + width / 2, 16, width - width / 2)
        case .topLeftBright:
          memset(line, 16, width)
          if row < rows / 2 { memset(line, 235, width / 2) }
        }
      }
    }

    // Chroma at the centre: the grey pattern has no colour.
    if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
      let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
      let base = plane.assumingMemoryBound(to: UInt8.self)
      for row in 0..<rows {
        memset(base + row * bytesPerRow, 128, width)
      }
    }
    return buffer
  }
}
