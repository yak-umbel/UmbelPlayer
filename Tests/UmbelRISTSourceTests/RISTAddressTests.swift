import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelRISTSource

final class RISTAddressTests: XCTestCase {
  private func parse(_ text: String) throws -> RISTAddress { try RISTAddress.parse(URL(string: text)!) }

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

  func testAnAddressGivesItsHostPortAndOptionsAsTheLibraryTakesThem() throws {
    let address = try parse("rist://sender.example:1968?buffer=500&secret=a%26b%3Dc%2Fd&aes-type=128&cname=player-1")
    XCTAssertEqual(address.host, "sender.example")
    XCTAssertEqual(address.port, 1968)
    XCTAssertEqual(address.numbers["buffer"], 500)
    XCTAssertEqual(address.numbers["aes-type"], 128)
    XCTAssertEqual(address.secret, "a&b=c/d", "the passphrase is what was typed, not its percent-encoding")
    XCTAssertEqual(address.cname, "player-1")
  }

  func testAnIPv6HostComesWithoutItsBrackets() throws {
    XCTAssertEqual(try parse("rist://[::1]:1968").host, "::1")
  }

  func testAnotherSchemeIsRefusedByName() {
    XCTAssertThrowsError(try parse("srt://h:1968")) {
      XCTAssertEqual($0 as? UmbelError, .unsupportedScheme("srt"))
    }
  }

  func testAnAddressWithoutAHostOrAPortIsRefused() {
    XCTAssertEqual(refusal("rist://:1968"), "address has no host")
    XCTAssertEqual(refusal("rist://h"), "address has no port")
    XCTAssertEqual(refusal("rist://h:0"), "address has no port")
  }

  func testAnAddressThatWouldMakeThePlayerListenIsRefused() {
    XCTAssertEqual(refusal("rist://@0.0.0.0:1968"), "address would make the player listen")
    XCTAssertEqual(refusal("rist://user@h:1968"), "address would make the player listen")
  }

  func testAPathOrAFragmentIsRefused() {
    XCTAssertEqual(refusal("rist://h:1968/stream"), "address has a path")
    XCTAssertEqual(refusal("rist://h:1968#x"), "address has a path")
    XCTAssertNoThrow(try parse("rist://h:1968/"))
  }

  func testOnlyTheListedOptionsGetThrough() {
    for name in [
      "miface", "ttl", "source", "local-port", "reflector", "username", "password", "srp-compat", "profile",
      "split", "merge", "verbose-level", "rtp-ptype", "multiplex-mode", "virt-src-port", "weight", "stream-id",
      "rtt-drop", "nothing-at-all",
    ] {
      XCTAssertEqual(refusal("rist://h:1968?\(name)=1"), "address option not allowed: \(name)", name)
    }
  }

  func testAnOptionMayNotBeGivenTwice() {
    XCTAssertEqual(refusal("rist://h:1968?buffer=100&buffer=200"), "address option given twice: buffer")
    XCTAssertEqual(refusal("rist://h:1968?secret=a&secret=b"), "address option given twice: secret")
  }

  func testANumberOutsideItsRangeOrNotANumberIsRefused() {
    let bad: [(String, String)] = [
      ("buffer", "0"), ("buffer", "-5"), ("buffer", "abc"), ("buffer", "60001"), ("buffer", "5.5"), ("buffer", ""),
      ("compression", "2"), ("congestion-control", "3"), ("timing-mode", "3"), ("virt-dst-port", "0"),
      ("virt-dst-port", "65536"), ("aes-type", "192"), ("aes-type", "0"), ("min-retries", "0"),
    ]
    for (name, value) in bad {
      XCTAssertEqual(refusal("rist://h:1968?\(name)=\(value)"), "address option \(name) is not valid", "\(name)=\(value)")
    }
  }

  func testAPassphraseAndANameHaveToFitWhatTheLibraryKeeps() {
    XCTAssertEqual(refusal("rist://h:1968?secret="), "address option secret is not valid")
    XCTAssertEqual(refusal("rist://h:1968?secret=\(String(repeating: "k", count: 128))"), "address option secret is not valid")
    XCTAssertNoThrow(try parse("rist://h:1968?secret=\(String(repeating: "k", count: 127))"))
    XCTAssertEqual(refusal("rist://h:1968?cname=\(String(repeating: "n", count: 128))"), "address option cname is not valid")
  }

  func testAConfigurationValueWinsOverTheAddress() throws {
    var address = try parse("rist://h:1968?buffer=500&secret=in-the-address")
    try address.set("buffer", "800")
    try address.set("secret", "in-the-configuration")
    XCTAssertEqual(address.numbers["buffer"], 800)
    XCTAssertEqual(address.secret, "in-the-configuration")
  }

  func testNothingInARefusalCarriesAPassphrase() {
    for text in [
      "rist://h:1968?secret=hunter2-hunter2&buffer=0", "rist://h:1968?secret=hunter2-hunter2&miface=en0",
      "rist://h:1968?secret=hunter2-hunter2&secret=hunter2-hunter2",
    ] {
      XCTAssertFalse((refusal(text) ?? "").contains("hunter2"), text)
    }
  }
}
