import CommonCrypto
import Foundation

/// Decrypts one AES-128 segment as it arrives, piece by piece: CBC with
/// PKCS#7 padding, the system's own implementation.
internal final class HLSDecryptor {
  enum Failure: Error {
    case keyNotSixteenBytes(Int)
    case cryptor(Int32)
  }

  private var cryptor: CCCryptorRef?

  init(key: Data, iv: Data) throws {
    guard key.count == kCCKeySizeAES128 else { throw Failure.keyNotSixteenBytes(key.count) }
    var made: CCCryptorRef?
    let status = key.withUnsafeBytes { key in
      iv.withUnsafeBytes { iv in
        CCCryptorCreate(
          CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
          key.baseAddress, key.count, iv.baseAddress, &made)
      }
    }
    guard status == kCCSuccess, let made else { throw Failure.cryptor(status) }
    cryptor = made
  }

  deinit {
    if let cryptor { CCCryptorRelease(cryptor) }
  }

  /// What `data` decrypts to so far. The last block is held back until
  /// `finish()`: it may be padding.
  func update(_ data: Data) throws -> Data {
    guard let cryptor else { return Data() }
    var output = Data(count: CCCryptorGetOutputLength(cryptor, data.count, false))
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      data.withUnsafeBytes { input in
        CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &written)
      }
    }
    guard status == kCCSuccess else { throw Failure.cryptor(status) }
    return output.prefix(written)
  }

  /// The last of it, padding taken off.
  func finish() throws -> Data {
    guard let cryptor else { return Data() }
    var output = Data(count: CCCryptorGetOutputLength(cryptor, 0, true))
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
      CCCryptorFinal(cryptor, out.baseAddress, out.count, &written)
    }
    guard status == kCCSuccess else { throw Failure.cryptor(status) }
    return output.prefix(written)
  }

  /// A segment's IV when the playlist names none: its sequence number, as a
  /// 128-bit big-endian number.
  static func iv(forSequence sequence: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: 16)
    var value = UInt64(max(0, sequence))
    for index in (8..<16).reversed() {
      bytes[index] = UInt8(value & 0xFF)
      value >>= 8
    }
    return Data(bytes)
  }
}

/// A playlist's keys, each fetched once however many segments use it.
internal actor HLSKeys {
  private let open: @Sendable (URL) async -> any UmbelRandomAccessSource
  private var fetched: [URL: Data] = [:]

  init(open: @escaping @Sendable (URL) async -> any UmbelRandomAccessSource) {
    self.open = open
  }

  func key(at url: URL) async throws -> Data {
    if let known = fetched[url] { return known }
    let source = await open(url)
    var bytes = Data()
    // A key is sixteen bytes; anything much longer is not one.
    while bytes.count <= 1_024 {
      let next = try await source.read(offset: Int64(bytes.count), maxLength: 1_024)
      if next.isEmpty { break }
      bytes += next
    }
    await source.invalidate()
    guard bytes.count == kCCKeySizeAES128 else { throw HLSDecryptor.Failure.keyNotSixteenBytes(bytes.count) }
    fetched[url] = bytes
    return bytes
  }
}

/// A source read once through from the start, decrypted on the way: an
/// encrypted segment FFmpeg's own playlist reading asks for.
internal actor HLSDecryptingReader {
  private let source: any UmbelRandomAccessSource
  private let decryptor: HLSDecryptor
  private var position: Int64 = 0
  private var isFinished = false

  init(source: any UmbelRandomAccessSource, key: Data, iv: Data) throws {
    self.source = source
    self.decryptor = try HLSDecryptor(key: key, iv: iv)
  }

  func read(maxLength: Int) async throws -> Data {
    while !isFinished {
      let data = try await source.read(offset: position, maxLength: maxLength)
      if data.isEmpty {
        isFinished = true
        await source.invalidate()
        return try decryptor.finish()
      }
      position += Int64(data.count)
      let plain = try decryptor.update(data)
      if !plain.isEmpty { return plain }
    }
    return Data()
  }
}
