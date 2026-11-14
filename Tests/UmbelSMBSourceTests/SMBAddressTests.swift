import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSMBSource

final class SMBAddressTests: XCTestCase {
  private func parse(_ text: String) throws -> SMBAddress { try SMBAddress.parse(URL(string: text)!) }

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

  func testAnAddressGivesItsServerShareFileAndLogin() throws {
    let address = try parse("smb://alice:p%40ss@nas.example:4455/media/shows/a%20b.mkv")
    XCTAssertEqual(address.host, "nas.example")
    XCTAssertEqual(address.port, 4455)
    XCTAssertEqual(address.share, "media")
    XCTAssertEqual(address.path, "shows/a b.mkv")
    XCTAssertEqual(address.user, "alice")
    XCTAssertEqual(address.password, "p@ss", "the password is what was typed, not its percent-encoding")
    XCTAssertNil(address.domain)
  }

  func testTheDomainIsBeforeTheUserAndASemicolon() throws {
    let address = try parse("smb://CORP;alice:secret@h/s/f")
    XCTAssertEqual(address.domain, "CORP")
    XCTAssertEqual(address.user, "alice")
  }

  func testWithoutAUserTheLoginIsGuest() throws {
    let address = try parse("smb://h/s/f")
    XCTAssertNil(address.user)
    XCTAssertNil(address.password)
    XCTAssertNil(address.port)
  }

  func testTheServerAsLibsmb2TakesIt() throws {
    XCTAssertEqual(try parse("smb://h/s/f").server, "h")
    XCTAssertEqual(try parse("smb://h:4455/s/f").server, "h:4455")
    XCTAssertEqual(try parse("smb://[::1]:4455/s/f").server, "[::1]:4455", "an IPv6 address is in brackets, as the library reads it")
    XCTAssertEqual(try parse("smb://[::1]/s/f").server, "[::1]")
  }

  func testAnotherSchemeIsRefusedByName() {
    XCTAssertThrowsError(try parse("nfs://h/s/f")) {
      XCTAssertEqual($0 as? UmbelError, .unsupportedScheme("nfs"))
    }
  }

  func testAnAddressWithoutAHostShareOrFileIsRefused() {
    XCTAssertEqual(refusal("smb:///s/f"), "address has no host")
    XCTAssertEqual(refusal("smb://h"), "address has no share")
    XCTAssertEqual(refusal("smb://h/"), "address has no share")
    XCTAssertEqual(refusal("smb://h/s"), "address has no file path")
    XCTAssertEqual(refusal("smb://h/s/"), "address has no file path")
    XCTAssertEqual(refusal("smb://h:0/s/f"), "address has an invalid port")
  }

  func testAnOptionIsRefused() {
    XCTAssertEqual(refusal("smb://h/s/f?sec=ntlm"), "address options not allowed")
  }

  func testEncryptionCannotBeRequiredOfAGuest() {
    let configuration = UmbelSMBSource.Configuration(requireEncryption: true)
    XCTAssertThrowsError(try UmbelSMBSource(url: URL(string: "smb://h/s/f")!, configuration: configuration)) {
      XCTAssertEqual($0 as? UmbelError, .sourceUnavailable(detail: "encryption needs a login"))
    }
    XCTAssertNoThrow(try UmbelSMBSource(url: URL(string: "smb://u:p@h/s/f")!, configuration: configuration))
  }

  func testNothingInARefusalCarriesTheAddress() {
    for text in ["smb://alice:hunter2@h/secretshare/secretfile?token=abc", "smb://alice:hunter2@/secretshare/f"] {
      _ = refusal(text).map {
        for secret in ["hunter2", "alice", "secretshare", "secretfile", "token", "abc"] {
          XCTAssertFalse($0.contains(secret), "\(secret) in \($0)")
        }
      }
    }
  }
}
