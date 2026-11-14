import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSFTPSource

final class SFTPAddressTests: XCTestCase {
  private func parse(_ text: String) throws -> SFTPAddress { try SFTPAddress.parse(URL(string: text)!) }

  func testAnAddressGivesItsHostPortPathAndLogin() throws {
    let address = try parse("sftp://alice:p%40ss@files.example:2222/media/a%20b.mkv")
    XCTAssertEqual(address.host, "files.example")
    XCTAssertEqual(address.port, 2222)
    XCTAssertEqual(address.path, "/media/a b.mkv")
    XCTAssertEqual(address.username, "alice")
    XCTAssertEqual(address.password, "p@ss", "the password is what was typed, not its percent-encoding")
  }

  func testThePortIsTheSSHOneUnlessSaid() throws {
    XCTAssertEqual(try parse("sftp://h/f").port, 22)
  }

  func testAnotherSchemeIsRefusedByName() {
    XCTAssertThrowsError(try parse("ftp://h/f")) {
      XCTAssertEqual($0 as? UmbelError, .unsupportedScheme("ftp"))
    }
  }

  func testAnAddressWithoutAFileHostOrWithAnOptionIsRefused() {
    for text in ["sftp://h", "sftp://h/", "sftp:///f", "sftp://h/f?timeout=1"] {
      XCTAssertThrowsError(try parse(text), text) {
        guard case .sourceUnavailable? = $0 as? UmbelError else { return XCTFail("\(text): \($0)") }
      }
    }
  }

  func testNothingInARefusalCarriesTheAddress() {
    for text in ["sftp://alice:hunter2@h/secret/path?token=abc", "sftp://alice:hunter2@/secret/path"] {
      XCTAssertThrowsError(try parse(text)) {
        let message = "\($0)"
        for secret in ["hunter2", "alice", "secret", "token", "abc"] {
          XCTAssertFalse(message.contains(secret), "\(secret) in \(message)")
        }
      }
    }
  }

  func testASourceWithoutAUserOrAWayToLogInIsRefusedBeforeAnythingIsOpened() {
    let key = URL(fileURLWithPath: "/nonexistent/key")
    func make(_ text: String, _ authentication: UmbelSFTPSource.Authentication?) throws {
      _ = try UmbelSFTPSource(
        url: URL(string: text)!, configuration: .init(authentication: authentication), hostKeyVerifier: { _ in true })
    }
    XCTAssertThrowsError(try make("sftp://h/f", .privateKey(file: key)), "no user") {
      XCTAssertEqual($0 as? UmbelError, .sourceUnavailable(detail: "address has no user name"))
    }
    XCTAssertThrowsError(try make("sftp://me@h/f", nil), "no way to log in") {
      XCTAssertEqual($0 as? UmbelError, .sourceUnavailable(detail: "no way to authenticate was given"))
    }
    XCTAssertThrowsError(try make("http://me@h/f", .privateKey(file: key))) {
      XCTAssertEqual($0 as? UmbelError, .unsupportedScheme("http"))
    }
    XCTAssertNoThrow(try make("sftp://me:pw@h/f", nil), "the address's own password is a way")
    XCTAssertNoThrow(try make("sftp://me@h/f", .password("pw")))
  }
}
