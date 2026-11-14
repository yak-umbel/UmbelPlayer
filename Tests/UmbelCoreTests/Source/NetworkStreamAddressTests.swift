import XCTest
@testable import UmbelCore

final class NetworkStreamAddressTests: XCTestCase {
  private let certificate = URL(fileURLWithPath: "/tmp/server.pem")

  private func protocols(_ text: String, certificate: URL? = nil) throws -> [String] {
    try NetworkStreamAddress.parse(try XCTUnwrap(URL(string: text)), certificateAuthorityFile: certificate).allowedProtocols
  }

  /// The system's TLS reads a certificate file through FFmpeg's `file`
  /// protocol. That is opened for the host's own file, and for nothing else:
  /// an address must never be able to name a file on this machine.
  func testFileIsOpenableOnlyForTheCertificateFileAHostGives() throws {
    XCTAssertFalse(try protocols("rtmps://h/a/b").contains("file"))
    XCTAssertFalse(try protocols("rtmpts://h/a/b").contains("file"))
    XCTAssertTrue(try protocols("rtmps://h/a/b", certificate: certificate).contains("file"))
    XCTAssertTrue(try protocols("rtmpts://h/a/b", certificate: certificate).contains("file"))
    for text in ["rtmp://h/a/b", "rtmpt://h/a/b", "udp://127.0.0.1:1", "tcp://127.0.0.1:1"] {
      XCTAssertFalse(try protocols(text, certificate: certificate).contains("file"), "a certificate means nothing to \(text)")
    }
  }

  func testTheCertificateFileIsHandedToTheSystemAsGiven() throws {
    let address = try NetworkStreamAddress.parse(
      try XCTUnwrap(URL(string: "rtmps://h/a/b")), certificateAuthorityFile: certificate)
    XCTAssertEqual(address.options["ca_file"], "/tmp/server.pem")
  }
}
