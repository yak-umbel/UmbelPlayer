import CommonCrypto
import XCTest
@testable import UmbelCore

final class HLSDecryptorTests: XCTestCase {
  private let key = Data((0..<16).map { UInt8($0) })
  private let iv = Data((0..<16).map { UInt8(15 - $0) })

  private func encrypt(_ plain: Data) -> Data {
    var output = Data(count: plain.count + kCCBlockSizeAES128)
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      plain.withUnsafeBytes { input in
        key.withUnsafeBytes { key in
          iv.withUnsafeBytes { iv in
            CCCrypt(
              CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
              key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
              out.baseAddress, out.count, &written)
          }
        }
      }
    }
    XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
    return output.prefix(written)
  }

  /// A segment arrives in pieces of any size, few of them whole blocks.
  func testPiecesOfAnySizeDecryptToTheWhole() throws {
    let plain = Data((0..<1_000).map { UInt8($0 % 251) })
    let cipher = encrypt(plain)
    let decryptor = try HLSDecryptor(key: key, iv: iv)
    var out = Data()
    var offset = 0
    while offset < cipher.count {
      let end = min(cipher.count, offset + 7)
      out += try decryptor.update(cipher.subdata(in: offset..<end))
      offset = end
    }
    out += try decryptor.finish()
    XCTAssertEqual(out, plain)
  }

  func testTheSequenceNumberAsAnIV() {
    XCTAssertEqual(HLSDecryptor.iv(forSequence: 5), Data(repeating: 0, count: 15) + Data([5]))
    XCTAssertEqual(HLSDecryptor.iv(forSequence: 0x0102), Data(repeating: 0, count: 14) + Data([1, 2]))
  }

  func testAKeyOfTheWrongSizeIsRefused() {
    XCTAssertThrowsError(try HLSDecryptor(key: Data("<html>".utf8), iv: iv))
  }
}
