import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelRISTSource

/// The reader on its own, called as the source's thread calls it: what the
/// source above it cannot show, as it buffers, splits and abandons.
final class RISTReaderTests: XCTestCase {
  private func reader(port: UInt16, connectTimeout: TimeInterval = 10) throws -> RISTReader {
    let address = try RISTAddress.parse(URL(string: "rist://127.0.0.1:\(port)?buffer=100")!)
    return RISTReader(address: address, profile: .main, connectTimeout: connectTimeout, stallTimeout: 10)
  }

  func testAReadGivesNoMoreThanItWasAskedFor() throws {
    let sender = try RISTTestPeer()
    defer { sender.stop() }
    let reader = try reader(port: sender.port)
    defer { reader.close() }
    try reader.open()
    sender.send()
    var total = 0
    while total < 20 * RISTTestPeer.payloadSize {
      let piece = try reader.read(maxLength: 100)
      XCTAssertFalse(piece.isEmpty)
      XCTAssertLessThanOrEqual(piece.count, 100)
      total += piece.count
    }
  }

  func testInterruptingEndsTheCallThatWaitsAndEveryOneAfter() throws {
    let nobody = try RISTTestPeer()
    nobody.stop()
    let reader = try reader(port: nobody.port, connectTimeout: 60)
    defer { reader.close() }
    try reader.open()
    let began = Date()
    Thread.detachNewThread {
      Thread.sleep(forTimeInterval: 0.3)
      reader.requestInterrupt()
    }
    XCTAssertThrowsError(try reader.read(maxLength: 1_000)) {
      XCTAssertEqual($0 as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 2, "not at the end of the connect deadline")
    XCTAssertThrowsError(try reader.read(maxLength: 1_000)) {
      XCTAssertEqual($0 as? UmbelError, .interrupted)
    }
  }

  func testAnInterruptBeforeOpeningStopsOpening() throws {
    let nobody = try RISTTestPeer()
    nobody.stop()
    let reader = try reader(port: nobody.port)
    reader.requestInterrupt()
    XCTAssertThrowsError(try reader.open()) { XCTAssertEqual($0 as? UmbelError, .interrupted) }
    reader.close()
  }
}
