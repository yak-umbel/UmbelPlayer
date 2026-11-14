import Foundation
import XCTest
@testable import UmbelFFmpegSupport

final class HEVCParameterSetOrderTests: XCTestCase {
  private func sample(_ types: [UInt8], lengthSize: Int = 4) -> Data {
    Data(types.flatMap { Array(repeating: UInt8(0), count: lengthSize - 1) + [3, $0 << 1, 1, 42] })
  }

  func testOnlyParameterSetsAfterThePictureMoveToTheNextSample() {
    for size in 1...4 {
      var order = HEVCParameterSetOrder(lengthSize: size)
      XCTAssertEqual(order.prepare(sample([32, 33, 34, 19, 40, 62, 32, 33, 34], lengthSize: size)),
                     sample([32, 33, 34, 19, 40, 62], lengthSize: size))
      XCTAssertEqual(order.prepare(sample([39, 1, 40, 62], lengthSize: size)),
                     sample([32, 33, 34, 39, 1, 40, 62], lengthSize: size))
      XCTAssertEqual(order.prepare(sample([0], lengthSize: size)), sample([0], lengthSize: size))
    }
  }

  func testAnnexBPreservesStartCodesAndOtherUnits() {
    var order = HEVCParameterSetOrder(lengthSize: nil)
    let picture = Data([0, 0, 1, 2, 1, 42, 0, 0, 0, 1, 124, 1, 42])
    let sets = Data([0, 0, 0, 1, 64, 1, 42, 0, 0, 1, 66, 1, 42])
    XCTAssertEqual(order.prepare(picture + sets), picture)
    XCTAssertEqual(order.prepare(picture), sets + picture)
    XCTAssertEqual(order.prepare(picture), picture)
  }

  func testResetDoesNotCarrySetsAcrossASeek() {
    var order = HEVCParameterSetOrder(lengthSize: 4)
    XCTAssertEqual(order.prepare(sample([1, 32, 33, 34])), sample([1]))
    order.reset()
    XCTAssertEqual(order.prepare(sample([19])), sample([19]))
  }

  func testDrainStaysEmptyEvenWithSetsWaiting() {
    var order = HEVCParameterSetOrder(lengthSize: 4)
    _ = order.prepare(sample([1, 32, 33, 34]))
    XCTAssertEqual(order.prepare(Data()), Data())
  }

  func testMalformedSamplesPassThroughWithoutLosingPendingSets() {
    var order = HEVCParameterSetOrder(lengthSize: 4)
    _ = order.prepare(sample([1, 32]))
    for malformed in [Data([0, 0]), Data([0, 0, 0, 99, 2, 1]), Data([0, 0, 0, 0])] {
      XCTAssertEqual(order.prepare(malformed), malformed)
    }
    XCTAssertEqual(order.prepare(sample([19])), sample([32, 19]))
  }

  func testAConfigurationBeforeThePictureStaysInThatSample() {
    var order = HEVCParameterSetOrder(lengthSize: 4)
    let bytes = sample([32, 33, 34, 39, 19, 40, 62])
    XCTAssertEqual(order.prepare(bytes), bytes)
    XCTAssertEqual(order.prepare(sample([1])), sample([1]))
  }
}
