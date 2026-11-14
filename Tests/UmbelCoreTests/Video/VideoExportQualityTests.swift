import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

final class VideoExportQualityTests: XCTestCase {
  private func frame() throws -> VideoFrame {
    let buffer = try XCTUnwrap(VideoFrame.makeTestP010PixelBuffer(width: 64, height: 64, luma: 500, cb: 512, cr: 512))
    return VideoFrame(presentationTime: .zero, pixelBuffer: buffer, width: 64, height: 64,
      color: .init(matrix: .bt709, range: .limited))
  }

  func testEightBitExportDithersWithoutBiasOrPausedFlicker() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let picture = try frame()
    let first = try FrameSnapshot.image(of: picture, size: CGSize(width: 64, height: 64), subtitles: [], device: device)
    let second = try FrameSnapshot.image(of: picture, size: CGSize(width: 64, height: 64), subtitles: [], device: device)
    let a = [UInt8](try XCTUnwrap(first.dataProvider?.data) as Data)
    let b = [UInt8](try XCTUnwrap(second.dataProvider?.data) as Data)
    XCTAssertEqual(a, b)
    let values = stride(from: 0, to: a.count, by: 4).map { Int(a[$0]) }
    XCTAssertEqual(Set(values), [138, 139])
    // Limited-range code -> BT.709 inverse OETF -> sRGB OETF -> 255.
    XCTAssertEqual(Double(values.reduce(0, +)) / Double(values.count), 138.805453, accuracy: 0.04)
  }

  func testSystemPixelsCannotBeExportedAsTheProcessedSystemPicture() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    var picture = try frame()
    picture.presentationRoute = .systemPixels
    XCTAssertThrowsError(try FrameSnapshot.image(of: picture, size: CGSize(width: 64, height: 64), subtitles: [], device: device))
  }
}
