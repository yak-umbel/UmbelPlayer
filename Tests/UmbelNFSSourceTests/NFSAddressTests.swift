import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelNFSSource

final class NFSAddressTests: XCTestCase {
  private func parse(_ text: String) throws -> NFSAddress { try NFSAddress.parse(URL(string: text)!) }

  private func refusal(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
    do {
      _ = try parse(text)
      XCTFail("\(text) was accepted", file: file, line: line)
      return nil
    } catch let error as UmbelError {
      guard case .sourceUnavailable(let detail) = error else {
        XCTFail("\(text): \(error)", file: file, line: line)
        return nil
      }
      return detail
    } catch {
      XCTFail("\(text): \(error)", file: file, line: line)
      return nil
    }
  }

  func testTheFileIsTheLastNameAndTheExportTheDirectoryItIsIn() throws {
    let address = try parse("nfs://nas.example/volume1/media/shows/a%20b.mkv")
    XCTAssertEqual(address.host, "nas.example")
    XCTAssertNil(address.port)
    XCTAssertNil(address.mountPort)
    XCTAssertEqual(address.export, "/volume1/media/shows")
    XCTAssertEqual(address.path, "a b.mkv")
  }

  func testAFileAtTheTopHasTheRootForItsExport() throws {
    let address = try parse("nfs://h/file.bin")
    XCTAssertEqual(address.export, "/")
    XCTAssertEqual(address.path, "file.bin")
  }

  func testTheExportOptionSaysWhereTheExportEnds() throws {
    let address = try parse("nfs://h/volume1/media/shows/s1/a.mkv?export=/volume1/media")
    XCTAssertEqual(address.export, "/volume1/media")
    XCTAssertEqual(address.path, "shows/s1/a.mkv")
  }

  func testThePortsAreGivenAsTheyAre() throws {
    let address = try parse("nfs://h:2050/e/f?mountport=20048")
    XCTAssertEqual(address.port, 2050)
    XCTAssertEqual(address.mountPort, 20048)
  }

  func testAnIPv6HostComesWithoutItsBrackets() throws {
    XCTAssertEqual(try parse("nfs://[::1]/e/f").host, "::1")
  }

  func testAnotherSchemeIsRefusedByName() {
    XCTAssertThrowsError(try parse("smb://h/e/f")) {
      XCTAssertEqual($0 as? UmbelError, .unsupportedScheme("smb"))
    }
  }

  func testAnAddressWithoutAHostOrAFileOrWithALoginIsRefused() {
    XCTAssertEqual(refusal("nfs:///e/f"), "address has no host")
    XCTAssertEqual(refusal("nfs://h"), "address has no file path")
    XCTAssertEqual(refusal("nfs://h/"), "address has no file path")
    XCTAssertEqual(refusal("nfs://h/e/"), "address has no file path")
    XCTAssertEqual(refusal("nfs://h:0/e/f"), "address has an invalid port")
    XCTAssertEqual(refusal("nfs://user@h/e/f"), "address has a login")
    XCTAssertEqual(refusal("nfs://user:secret@h/e/f"), "address has a login")
  }

  func testTheExportHasToHoldTheFile() {
    XCTAssertEqual(refusal("nfs://h/a/b/c?export=/a/b/c"), "address is not a file in the export")
    XCTAssertEqual(refusal("nfs://h/a/b/c?export=/x"), "address is not a file in the export")
    XCTAssertEqual(refusal("nfs://h/a/b/c?export=a"), "address option export is not valid")
    XCTAssertEqual(refusal("nfs://h/a/b/c?export="), "address option export is not valid")
  }

  func testOnlyTheTwoOptionsGetThroughAndOnceEach() {
    XCTAssertEqual(refusal("nfs://h/e/f?version=4"), "address option not allowed: version")
    XCTAssertEqual(refusal("nfs://h/e/f?uid=0"), "address option not allowed: uid")
    XCTAssertEqual(refusal("nfs://h/e/f?mountport=1&mountport=2"), "address option given twice: mountport")
    for value in ["0", "70000", "abc", "-1", "+5", ""] {
      XCTAssertEqual(refusal("nfs://h/e/f?mountport=\(value)"), "address option mountport is not valid", value)
    }
  }

  func testNothingInARefusalCarriesTheAddress() {
    for text in ["nfs://alice:hunter2@h/secretexport/secretfile", "nfs://h/secretexport/secretfile?token=abc"] {
      _ = refusal(text).map {
        for secret in ["hunter2", "alice", "secretexport", "secretfile", "abc"] {
          XCTAssertFalse($0.contains(secret), "\(secret) in \($0)")
        }
      }
    }
  }
}
