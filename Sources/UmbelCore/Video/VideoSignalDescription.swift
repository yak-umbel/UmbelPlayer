import Foundation

/// The declared signal is retained separately from each frame's actual format.
public struct VideoSignalDescription: Sendable, Equatable {
  public let pixels: VideoPixelDescription?
  public let transferCode: Int32
  public let primariesCode: Int32
  public let matrixCode: Int32
  public let rangeCode: Int32
  public let dynamicHDR: UmbelDynamicHDR?

  public init(
    pixels: VideoPixelDescription? = nil, transferCode: Int32 = 2,
    primariesCode: Int32 = 2, matrixCode: Int32 = 2, rangeCode: Int32 = 0,
    dynamicHDR: UmbelDynamicHDR? = nil
  ) {
    self.pixels = pixels
    self.transferCode = transferCode
    self.primariesCode = primariesCode
    self.matrixCode = matrixCode
    self.rangeCode = rangeCode
    self.dynamicHDR = dynamicHDR
  }
}
