import CoreGraphics
import CoreVideo
import Foundation

/// Biplanar pixel buffers drawn and read pixel by pixel for the
/// deinterlacing tests. Values are normalised, 0...1, at 8 or 10 bits.
enum InterlaceTestBuffers {
  static let eightBit = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  static let tenBit = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

  /// `luma(x, y)` per luma pixel; `chroma(x, y)` per chroma pixel (half size).
  static func make(
    width: Int, height: Int, format: OSType = eightBit,
    luma: (Int, Int) -> Float,
    chroma: (Int, Int) -> (Float, Float) = { _, _ in (0.5, 0.5) }
  ) -> CVPixelBuffer {
    var made: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &made)
    let buffer = made!
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<2 {
      let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
        let row = base.advanced(by: y * rowBytes)
        for x in 0..<CVPixelBufferGetWidthOfPlane(buffer, plane) {
          let values: [Float]
          if plane == 0 { values = [luma(x, y)] } else { let pair = chroma(x, y); values = [pair.0, pair.1] }
          for (channel, value) in values.enumerated() {
            let index = x * values.count + channel
            if format == tenBit {
              row.assumingMemoryBound(to: UInt16.self)[index] = UInt16((value * 1023).rounded()) << 6
            } else {
              row.assumingMemoryBound(to: UInt8.self)[index] = UInt8((value * 255).rounded())
            }
          }
        }
      }
    }
    return buffer
  }

  static func luma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> Float {
    sample(buffer, plane: 0, channels: 1, channel: 0, x: x, y: y)
  }

  static func chroma(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (Float, Float) {
    (sample(buffer, plane: 1, channels: 2, channel: 0, x: x, y: y),
     sample(buffer, plane: 1, channels: 2, channel: 1, x: x, y: y))
  }

  private static func sample(
    _ buffer: CVPixelBuffer, plane: Int, channels: Int, channel: Int, x: Int, y: Int
  ) -> Float {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let row = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
      .advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, plane))
    let index = x * channels + channel
    if CVPixelBufferGetPixelFormatType(buffer) == tenBit {
      return Float(row.assumingMemoryBound(to: UInt16.self)[index] >> 6) / 1023
    }
    return Float(row.assumingMemoryBound(to: UInt8.self)[index]) / 255
  }

  /// The share of luma pixels standing out from both vertical neighbours the
  /// same way by more than `threshold`: what weaving two fields of a moving
  /// picture leaves.
  static func combShare(_ buffer: CVPixelBuffer, threshold: Float = 0.1) -> Double {
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    // Locked once: a lock for every pixel read makes this minutes on a simulator.
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let tenBits = CVPixelBufferGetPixelFormatType(buffer) == tenBit
    func value(_ x: Int, _ y: Int) -> Float {
      let row = base.advanced(by: y * rowBytes)
      if tenBits { return Float(row.assumingMemoryBound(to: UInt16.self)[x] >> 6) / 1023 }
      return Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
    }
    var combed = 0
    for y in 1..<(height - 1) {
      for x in 0..<width {
        let here = value(x, y)
        let up = here - value(x, y - 1), down = here - value(x, y + 1)
        if (up > threshold && down > threshold) || (up < -threshold && down < -threshold) { combed += 1 }
      }
    }
    return Double(combed) / Double(width * (height - 2))
  }

  /// The same for an sRGB BGRA image, by its green channel.
  static func combShare(_ image: CGImage, threshold: Int = 25) -> Double {
    let bytes = image.dataProvider!.data! as Data
    func green(_ x: Int, _ y: Int) -> Int { Int(bytes[y * image.bytesPerRow + x * 4 + 1]) }
    var combed = 0
    for y in 1..<(image.height - 1) {
      for x in 0..<image.width {
        let up = green(x, y) - green(x, y - 1), down = green(x, y) - green(x, y + 1)
        if (up > threshold && down > threshold) || (up < -threshold && down < -threshold) { combed += 1 }
      }
    }
    return Double(combed) / Double(image.width * (image.height - 2))
  }
}
