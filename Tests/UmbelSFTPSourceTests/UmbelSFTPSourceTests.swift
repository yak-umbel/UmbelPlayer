import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSFTPSource

final class UmbelSFTPSourceTests: XCTestCase {
  private var server: SSHDFixture!
  private var silent: SilentServer?
  private let content = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })

  override func setUpWithError() throws {
    server = try SSHDFixture.start()
  }

  override func tearDown() {
    server?.stop()
    silent?.stop()
  }

  private func source(
    path: String, user: String? = nil, password: String? = nil,
    authentication: UmbelSFTPSource.Authentication? = nil, loginWithKey: Bool = true,
    connectTimeout: TimeInterval = 10, stallTimeout: TimeInterval = 10,
    trusting verifier: (@Sendable (UmbelSFTPSource.HostKey) -> Bool)? = nil
  ) throws -> UmbelSFTPSource {
    try UmbelSFTPSource(
      url: server.url(path: path, user: user, password: password),
      configuration: .init(
        connectTimeout: connectTimeout, stallTimeout: stallTimeout,
        authentication: authentication ?? (loginWithKey ? .privateKey(file: server.ed25519Key) : nil)),
      hostKeyVerifier: verifier ?? UmbelSFTPSource.trusting(fingerprints: [server.hostFingerprint]))
  }

  private func readAll(_ source: UmbelSFTPSource, chunk: Int = 100_000) async throws -> Data {
    var all = Data()
    while true {
      let piece = try await source.read(offset: Int64(all.count), maxLength: chunk)
      if piece.isEmpty { return all }
      all.append(piece)
    }
  }

  // ── Reading ─────────────────────────────────────────

  func testAFileIsReadWholeAndItsLengthIsKnown() async throws {
    let path = try server.serve("movie.bin", content)
    let source = try source(path: path)
    let length = await source.contentLength
    XCTAssertEqual(length, Int64(content.count))
    let all = try await readAll(source)
    XCTAssertEqual(all.count, content.count)
    XCTAssertEqual(all, content)
    await source.invalidate()
  }

  func testAReadFromElsewhereRepositionsAndOneFromWhereTheLastEndedGoesOn() async throws {
    let path = try server.serve("movie.bin", content)
    let source = try source(path: path)
    let first = try await source.read(offset: 1_000_000, maxLength: 4_096)
    XCTAssertEqual(first, content[1_000_000..<1_004_096] as Data)
    let next = try await source.read(offset: 1_000_000 + Int64(first.count), maxLength: 4_096)
    XCTAssertEqual(next, content[(1_000_000 + first.count)..<(1_000_000 + first.count + next.count)] as Data)
    let back = try await source.read(offset: 10, maxLength: 100)
    XCTAssertEqual(back, content[10..<(10 + back.count)] as Data, "backwards too")
    await source.invalidate()
  }

  func testAReadAtOrPastTheEndIsEmpty() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(path: path)
    let atEnd = try await source.read(offset: 100, maxLength: 10)
    XCTAssertTrue(atEnd.isEmpty)
    let past = try await source.read(offset: 5_000, maxLength: 10)
    XCTAssertTrue(past.isEmpty)
    await source.invalidate()
  }

  func testEveryKindOfKeyLogsIn() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let kinds: [(String, UmbelSFTPSource.Authentication)] = [
      ("ed25519", .privateKey(file: server.ed25519Key)),
      ("rsa pem", .privateKey(file: server.rsaKey)),
      ("with a public key beside", .privateKey(file: server.ed25519Key, publicKeyFile: server.ed25519Key.appendingPathExtension("pub"))),
      ("encrypted", .privateKey(file: server.encryptedKey, passphrase: server.encryptedKeyPassphrase)),
    ]
    for (name, authentication) in kinds {
      let source = try source(path: path, authentication: authentication)
      let data = try await source.read(offset: 0, maxLength: 100)
      XCTAssertEqual(data.count, 100, name)
      await source.invalidate()
    }
  }

  func testAReadAfterInvalidatingIsInterrupted() async throws {
    let path = try server.serve("movie.bin", content)
    let source = try source(path: path)
    _ = try await source.read(offset: 0, maxLength: 100)
    await source.invalidate()
    do {
      _ = try await source.read(offset: 0, maxLength: 100)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
  }

  func testAfterACancelledReadTheNextOneConnectsAgain() async throws {
    let path = try server.serve("movie.bin", content)
    let source = try source(path: path, stallTimeout: 60)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let processes = server.connectionProcesses()
    for pid in processes { kill(pid, SIGSTOP) }
    let task = Task { try await source.read(offset: 1_200_000, maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    for pid in processes { kill(pid, SIGCONT) }
    let again = try await source.read(offset: 1_200_000, maxLength: 1_000)
    XCTAssertEqual(again, content[1_200_000..<(1_200_000 + again.count)] as Data)
    XCTAssertFalse(again.isEmpty)
    let log = server.log(waitingFor: "Accepted publickey")
    XCTAssertEqual(log.components(separatedBy: "Accepted publickey").count - 1, 2, "two connections:\n\(log)")
    await source.invalidate()
  }

  // ── The host key ────────────────────────────────────

  func testTheVerifierSeesTheFingerprintTheServerHas() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let seen = Locked<[UmbelSFTPSource.HostKey]>([])
    let source = try source(path: path, trusting: { key in seen.withValue { $0.append(key) }; return true })
    _ = try await source.read(offset: 0, maxLength: 10)
    await source.invalidate()
    let key = try XCTUnwrap(seen.value.first)
    XCTAssertEqual(key.fingerprint, server.hostFingerprint, "as ssh-keygen prints it")
    XCTAssertEqual(key.type, "ssh-ed25519")
    XCTAssertEqual(key.sha256.count, 32)
    XCTAssertFalse(key.raw.isEmpty)
  }

  func testAKeyNobodyTrustsEndsTheConnectionBeforeAnyCredentialIsSent() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(path: path, trusting: { _ in false })
    do {
      _ = try await source.read(offset: 0, maxLength: 10)
      XCTFail("a read went through")
    } catch let error as UmbelError {
      guard case .sourceUnavailable(let detail) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(detail, "host key not trusted")
    }
    let log = server.log(waitingFor: "Connection closed")
    XCTAssertTrue(log.contains("Connection from") || log.contains("kex"), "the server was reached:\n\(log)")
    XCTAssertFalse(log.contains("userauth-request"), "no login was tried:\n\(log)")
    XCTAssertFalse(log.contains("Accepted"), log)
    await source.invalidate()
  }

  func testAnotherKeysFingerprintIsNotTrusted() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let other = "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let source = try source(path: path, trusting: UmbelSFTPSource.trusting(fingerprints: [other]))
    do {
      _ = try await source.read(offset: 0, maxLength: 10)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "host key not trusted"))
    }
    await source.invalidate()
  }

  func testTheFingerprintListTakesTheOpenSSHFormAndTheBareDigest() {
    let digest = Data((0..<32).map { UInt8($0) })
    let key = UmbelSFTPSource.HostKey(type: "ssh-ed25519", raw: Data([1, 2, 3]), sha256: digest)
    let bare = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
    XCTAssertEqual(key.fingerprint, "SHA256:" + bare)
    XCTAssertTrue(UmbelSFTPSource.trusting(fingerprints: [key.fingerprint])(key))
    XCTAssertTrue(UmbelSFTPSource.trusting(fingerprints: [bare])(key))
    XCTAssertFalse(UmbelSFTPSource.trusting(fingerprints: [])(key), "an empty list trusts nobody")
    XCTAssertFalse(UmbelSFTPSource.trusting(fingerprints: ["SHA256:" + bare.dropLast() + "A"])(key))
  }

  // ── Failures ────────────────────────────────────────

  func testAKeyTheServerDoesNotKnowIsRefusedWithoutSayingWhat() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(path: path, authentication: .privateKey(file: server.strangerKey))
    do {
      _ = try await source.read(offset: 0, maxLength: 10)
      XCTFail("a read went through")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .sourceUnavailable(detail: "authentication failed"))
    }
    await source.invalidate()
  }

  func testAWrongPassphraseAndAWrongPasswordAreRefusedAndNeverEchoed() async throws {
    let path = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let attempts: [(String, UmbelSFTPSource.Authentication?, String?)] = [
      ("passphrase", .privateKey(file: server.encryptedKey, passphrase: "wrong-passphrase"), nil),
      ("password", nil, "hunter2-the-wrong-one"),
    ]
    for (name, authentication, password) in attempts {
      let source = try source(
        path: path, password: password, authentication: authentication, loginWithKey: authentication != nil)
      do {
        _ = try await source.read(offset: 0, maxLength: 10)
        XCTFail("\(name): a read went through")
      } catch let error as UmbelError {
        guard case .sourceUnavailable = error else { return XCTFail("\(name): \(error)") }
        for secret in ["wrong-passphrase", "hunter2", path, server.username] {
          XCTAssertFalse("\(error)".contains(secret), "\(name): \(secret) in \(error)")
        }
      }
      await source.invalidate()
    }
  }

  func testAMissingFileIsSaidWithoutItsName() async throws {
    let source = try source(path: server.root.appendingPathComponent("not-there-at-all.bin").path)
    do {
      _ = try await source.read(offset: 0, maxLength: 10)
      XCTFail("a read went through")
    } catch let error as UmbelError {
      XCTAssertEqual(error, .sourceUnavailable(detail: "file could not be opened"))
      XCTAssertFalse("\(error)".contains("not-there"))
    }
    await source.invalidate()
  }

  func testAServerThatNeverAnswersIsGivenUpOnAtTheConnectDeadline() async throws {
    let quiet = try SilentServer()
    silent = quiet
    let source = try UmbelSFTPSource(
      url: URL(string: "sftp://me@127.0.0.1:\(quiet.port)/f")!,
      configuration: .init(connectTimeout: 0.6, authentication: .privateKey(file: server.ed25519Key)),
      hostKeyVerifier: { _ in true })
    let began = Date()
    do {
      _ = try await source.read(offset: 0, maxLength: 10)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "connection timed out"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    await source.invalidate()
  }

  func testACancelledReadGivesUpAtOnceWhateverTheDeadline() async throws {
    let quiet = try SilentServer()
    silent = quiet
    let source = try UmbelSFTPSource(
      url: URL(string: "sftp://me@127.0.0.1:\(quiet.port)/f")!,
      configuration: .init(connectTimeout: 60, authentication: .privateKey(file: server.ed25519Key)),
      hostKeyVerifier: { _ in true })
    let began = Date()
    let task = Task { try await source.read(offset: 0, maxLength: 10) }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    await source.invalidate()
  }

  func testATransferThatGoesQuietIsGivenUpOnAtTheStallDeadline() async throws {
    let path = try server.serve("movie.bin", content)
    let source = try source(path: path, stallTimeout: 0.8)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let processes = server.connectionProcesses()
    XCTAssertFalse(processes.isEmpty)
    for pid in processes { kill(pid, SIGSTOP) }
    let began = Date()
    do {
      _ = try await source.read(offset: 1_200_000, maxLength: 1_000)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "no data received"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 4)
    for pid in processes { kill(pid, SIGCONT) }
    await source.invalidate()
  }
}

/// A value several threads touch, for a verifier that is called from the
/// source's own.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
