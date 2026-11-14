import CoreMedia
import XCTest
@testable import UmbelCore

final class VideoPresentationOrderTests: XCTestCase {
  private func frame(_ pts: Int64) throws -> VideoFrame {
    let pixels = try XCTUnwrap(VideoFrame.makeTestPixelBuffer(width: 4, height: 4, luma: 128, cb: 128, cr: 128))
    return VideoFrame(presentationTime: CMTime(value: pts, timescale: 25), pixelBuffer: pixels,
      width: 4, height: 4, color: .init(matrix: .bt709, range: .limited))
  }

  func testDecodeOrderCallbacksAreReleasedInPresentationOrder() throws {
    var order = VideoPresentationOrder()
    try order.append([try frame(0), try frame(3)])
    XCTAssertEqual(order.take(through: .zero).map(\.presentationTime), [.zero])
    try order.append([try frame(1)])
    XCTAssertEqual(order.take(through: CMTime(value: 1, timescale: 25)).map(\.presentationTime), [CMTime(value: 1, timescale: 25)])
    try order.append([try frame(2)])
    XCTAssertEqual(order.take(through: CMTime(value: 2, timescale: 25)).map(\.presentationTime), [CMTime(value: 2, timescale: 25)])
    XCTAssertEqual(order.drain().map(\.presentationTime), [CMTime(value: 3, timescale: 25)])
  }

  func testFlushDiscardsThePreviousEpochsPictures() throws {
    var order = VideoPresentationOrder()
    try order.append([try frame(3)])
    order.reset()
    XCTAssertTrue(order.drain().isEmpty)
  }

  func testRetainedNativeSurfacesHaveABoundedBudget() throws {
    var order = VideoPresentationOrder(limitBytes: 1)
    XCTAssertThrowsError(try order.append([try frame(0)]))
  }
}
