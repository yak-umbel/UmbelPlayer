import CoreGraphics
import XCTest
@testable import UmbelCore

final class SubtitlePlacementTests: XCTestCase {
  private func bitmap(_ frame: CGRect) throws -> UmbelSubtitleBitmap {
    let provider = try XCTUnwrap(CGDataProvider(data: Data([255, 255, 255, 255]) as CFData))
    let image = try XCTUnwrap(CGImage(
      width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    return UmbelSubtitleBitmap(image: image, frame: frame)
  }

  func testZeroPlacementPreservesAuthoredFrames() throws {
    let authored = [try bitmap(CGRect(x: 10, y: 95, width: 20, height: 10))]
    let placed = UmbelSubtitlePlacement().apply(to: authored, in: CGSize(width: 100, height: 100))
    XCTAssertEqual(placed[0].frame, authored[0].frame)
  }

  func testOffsetAndBottomInsetMoveTheWholeGroupTogether() throws {
    let authored = [
      try bitmap(CGRect(x: 10, y: 60, width: 20, height: 10)),
      try bitmap(CGRect(x: 40, y: 80, width: 20, height: 10)),
    ]
    let placement = UmbelSubtitlePlacement(verticalOffset: 0.1, bottomInset: 0.3)
    let placed = placement.apply(to: authored, in: CGSize(width: 100, height: 100))
    XCTAssertEqual(placed[0].frame.minY, 40, accuracy: 0.001)
    XCTAssertEqual(placed[1].frame.minY, 60, accuracy: 0.001)
    XCTAssertEqual(placed[0].frame.minX, 10, accuracy: 0.001)
  }

  func testOversizedGroupAnchorsAtTopWithoutChangingSpacing() throws {
    let authored = [
      try bitmap(CGRect(x: 10, y: 40, width: 20, height: 20)),
      try bitmap(CGRect(x: 10, y: 70, width: 20, height: 20)),
    ]
    let placement = UmbelSubtitlePlacement(bottomInset: 0.6)
    let placed = placement.apply(to: authored, in: CGSize(width: 100, height: 100))
    XCTAssertEqual(placed[0].frame.minY, 0, accuracy: 0.001)
    XCTAssertEqual(placed[1].frame.minY, 30, accuracy: 0.001)
  }
}
