import XCTest
@testable import UmbelCore

final class SubtitleEncodingTests: XCTestCase {
  private func encoding(_ cf: CFStringEncodings) -> String.Encoding {
    String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
  }

  private let simplified = "1\n00:00:01,000 --> 00:00:02,000\n简体中文字幕，国标编码。\n"
  private let traditional = "1\n00:00:01,000 --> 00:00:05,000\n這是繁體中文字幕，用來檢驗大五碼。\n"

  private func decoded(_ data: Data?) -> String? {
    data.flatMap { String(data: $0, encoding: .utf8) }
  }

  func testValidUTF8PassesThrough() {
    let data = Data(simplified.utf8)
    XCTAssertEqual(SubtitleEncoding.utf8(from: data), data)
  }

  /// A byte order mark is an encoding declaration, not text. Checked on the
  /// bytes: decoding to a String would hide it, since Foundation drops a
  /// leading mark on its own — but not every consumer of the bytes does.
  func testUTF8ByteOrderMarkIsRemoved() {
    let data = Data([0xEF, 0xBB, 0xBF]) + Data(simplified.utf8)
    XCTAssertEqual(SubtitleEncoding.utf8(from: data), Data(simplified.utf8))
  }

  func testUTF16WithByteOrderMarkIsConverted() throws {
    let data = try XCTUnwrap(simplified.data(using: .utf16))  // includes a BOM
    XCTAssertEqual(decoded(SubtitleEncoding.utf8(from: data)), simplified)
  }

  func testGBKIsDetectedAndConverted() throws {
    let data = try XCTUnwrap(simplified.data(using: encoding(.GB_18030_2000)))
    XCTAssertEqual(decoded(SubtitleEncoding.utf8(from: data)), simplified)
  }

  func testBig5IsDetectedAndConverted() throws {
    let data = try XCTUnwrap(traditional.data(using: encoding(.big5)))
    XCTAssertEqual(decoded(SubtitleEncoding.utf8(from: data)), traditional)
  }
}
