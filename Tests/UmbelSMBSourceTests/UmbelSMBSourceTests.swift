import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSMBSource

final class UmbelSMBSourceTests: XCTestCase {
  private var server: SambaFixture!
  private var silent: SilentServer?
  private var sources: [UmbelSMBSource] = []
  private let content = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })

  override func tearDown() async throws {
    for source in sources { await source.invalidate() }
    sources = []
    server?.stop()
    silent?.stop()
  }

  private func start(signing: SambaFixture.Mode = .optional, encryption: SambaFixture.Mode = .optional) throws {
    server = try SambaFixture.start(signing: signing, encryption: encryption)
  }

  private func source(
    _ url: URL, connectTimeout: TimeInterval = 10, stallTimeout: TimeInterval = 10,
    requireEncryption: Bool = false
  ) throws -> UmbelSMBSource {
    let made = try UmbelSMBSource(
      url: url,
      configuration: .init(connectTimeout: connectTimeout, stallTimeout: stallTimeout, requireEncryption: requireEncryption))
    sources.append(made)
    return made
  }

  private func readAll(_ source: UmbelSMBSource, chunk: Int = 400_000) async throws -> Data {
    var all = Data()
    while true {
      let piece = try await source.read(offset: Int64(all.count), maxLength: chunk)
      if piece.isEmpty { return all }
      all.append(piece)
    }
  }

  private func failure(of source: UmbelSMBSource, offset: Int64 = 0) async -> UmbelError? {
    do {
      _ = try await source.read(offset: offset, maxLength: 1_000)
      XCTFail("a read went through")
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  // ── Reading ─────────────────────────────────────────

  func testAFileIsReadWholeAndItsLengthIsKnown() async throws {
    try start()
    let name = try server.serve("movie.bin", content)
    let source = try source(server.url(path: name))
    let length = await source.contentLength
    XCTAssertEqual(length, Int64(content.count))
    let all = try await readAll(source)
    XCTAssertEqual(all.count, content.count)
    XCTAssertEqual(all, content)
  }

  func testAReadFromAnywhereGivesTheBytesThereInAnyOrder() async throws {
    try start()
    let name = try server.serve("movie.bin", content)
    let source = try source(server.url(path: name))
    let middle = try await source.read(offset: 1_000_000, maxLength: 4_096)
    XCTAssertEqual(middle, content[1_000_000..<1_004_096] as Data)
    let next = try await source.read(offset: 1_000_000 + Int64(middle.count), maxLength: 4_096)
    XCTAssertEqual(next, content[(1_000_000 + middle.count)..<(1_000_000 + middle.count + next.count)] as Data)
    let back = try await source.read(offset: 10, maxLength: 100)
    XCTAssertEqual(back, content[10..<(10 + back.count)] as Data)
  }

  func testAReadAtOrPastTheEndIsEmpty() async throws {
    try start()
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(server.url(path: name))
    let tail = try await source.read(offset: 90, maxLength: 1_000)
    XCTAssertEqual(tail.count, 10)
    let atEnd = try await source.read(offset: 100, maxLength: 10)
    XCTAssertTrue(atEnd.isEmpty)
    let past = try await source.read(offset: 5_000, maxLength: 10)
    XCTAssertTrue(past.isEmpty)
  }

  func testAFileInASubfolderWithASpaceInItsNameIsRead() async throws {
    try start()
    try FileManager.default.createDirectory(at: server.root.appendingPathComponent("a folder"), withIntermediateDirectories: true)
    _ = try server.serve("a folder/the file.bin", Data(repeating: 9, count: 50))
    let source = try source(server.url(path: "a folder/the file.bin"))
    let data = try await source.read(offset: 0, maxLength: 100)
    XCTAssertEqual(data, Data(repeating: 9, count: 50))
  }

  // ── Logging in ──────────────────────────────────────

  func testAGuestReadsWhatAShareOffersGuests() async throws {
    try start()
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(server.url(share: "open", path: name, login: false))
    let data = try await source.read(offset: 0, maxLength: 100)
    XCTAssertEqual(data.count, 100)
  }

  func testAGuestIsRefusedWhereTheShareWantsALogin() async throws {
    try start()
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(server.url(path: name, login: false))
    let error = await failure(of: source)
    guard case .sourceUnavailable(let detail)? = error else { return XCTFail("\(String(describing: error))") }
    XCTAssertTrue(["authentication failed", "access denied"].contains(detail), detail)
  }

  func testAWrongPasswordAndAnUnknownUserAreRefusedAndNeverEchoed() async throws {
    try start()
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    // A user the server does not know is, with its "bad user" mapping, a guest, and is
    // then turned away from the share instead of at the login.
    let attempts: [(String, URL, [String])] = [
      ("password", server.url(path: name, password: "wrong-password-xyz"), ["authentication failed"]),
      ("user", server.url(path: name, user: "nobodyatall"), ["authentication failed", "access denied"]),
    ]
    for (what, url, expected) in attempts {
      let source = try source(url)
      let error = await failure(of: source)
      guard case .sourceUnavailable(let detail)? = error else { XCTFail("\(what): \(String(describing: error))"); continue }
      XCTAssertTrue(expected.contains(detail), "\(what): \(detail)")
      for secret in ["wrong-password-xyz", "nobodyatall", server.username, name, "share"] {
        XCTAssertFalse("\(String(describing: error))".contains(secret), "\(what): \(secret) in \(String(describing: error))")
      }
    }
  }

  func testTheConfigurationsPasswordWinsOverTheAddresss() async throws {
    try start()
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let made = try UmbelSMBSource(
      url: server.url(path: name, password: "not-the-password"),
      configuration: .init(connectTimeout: 10, password: server.password))
    sources.append(made)
    let data = try await made.read(offset: 0, maxLength: 100)
    XCTAssertEqual(data.count, 100)
  }

  func testAShareThatIsNotThereAndAFileThatIsNotThereAreSaidSoWithoutTheirNames() async throws {
    try start()
    let cases: [(String, URL, String)] = [
      ("share", server.url(share: "noshare", path: "x.bin"), "share not found"),
      ("file", server.url(path: "not-there-at-all.bin"), "file not found"),
    ]
    for (what, url, expected) in cases {
      let source = try source(url)
      let error = await failure(of: source)
      XCTAssertEqual(error, .sourceUnavailable(detail: expected), what)
      XCTAssertFalse("\(String(describing: error))".contains("not-there"))
    }
  }

  // ── Signing and encryption ──────────────────────────

  /// Signing is used when the server asks for it; no setting is needed.
  func testAServerThatRequiresSigningIsRead() async throws {
    try start(signing: .required)
    let name = try server.serve("movie.bin", content)
    let source = try source(server.url(path: name))
    let all = try await readAll(source)
    XCTAssertEqual(all, content)
  }

  func testAnEncryptingServerIsReadAndEncryptionCanBeRequired() async throws {
    try start(encryption: .required)
    let name = try server.serve("movie.bin", content)
    let source = try source(server.url(path: name), requireEncryption: true)
    let all = try await readAll(source)
    XCTAssertEqual(all, content)
  }

  func testEncryptionIsRefusedWhereTheServerDoesNotDoIt() async throws {
    try start(encryption: .off)
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(server.url(path: name), requireEncryption: true)
    let error = await failure(of: source)
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
  }

  // ── Silence, cancelling ─────────────────────────────

  func testAServerThatNeverAnswersIsGivenUpOnAtTheConnectDeadline() async throws {
    let quiet = try SilentServer()
    silent = quiet
    let source = try source(URL(string: "smb://u:p@127.0.0.1:\(quiet.port)/share/f.bin")!, connectTimeout: 0.6)
    let began = Date()
    let error = await failure(of: source)
    XCTAssertEqual(error, .sourceUnavailable(detail: "connection timed out"))
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
  }

  func testACancelledReadGivesUpAtOnceWhateverTheDeadline() async throws {
    let quiet = try SilentServer()
    silent = quiet
    let source = try source(URL(string: "smb://u:p@127.0.0.1:\(quiet.port)/share/f.bin")!, connectTimeout: 60)
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
  }

  func testATransferThatGoesQuietIsGivenUpOnAtTheStallDeadline() async throws {
    try start()
    let name = try server.serve("movie.bin", content)
    let source = try source(server.url(path: name), stallTimeout: 0.8)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    let processes = server.connectionProcesses()
    XCTAssertFalse(processes.isEmpty)
    for pid in processes { kill(pid, SIGSTOP) }
    let began = Date()
    let error = await failure(of: source, offset: 1_200_000)
    XCTAssertEqual(error, .sourceUnavailable(detail: "no data received"))
    XCTAssertLessThan(Date().timeIntervalSince(began), 4)
    for pid in processes { kill(pid, SIGCONT) }
  }

  func testAfterACancelledReadTheNextOneConnectsAgain() async throws {
    try start()
    let name = try server.serve("movie.bin", content)
    let source = try source(server.url(path: name), stallTimeout: 60)
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
    XCTAssertFalse(again.isEmpty)
    XCTAssertEqual(again, content[1_200_000..<(1_200_000 + again.count)] as Data)
  }

  func testAReadAfterInvalidatingIsInterrupted() async throws {
    try start()
    let name = try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(server.url(path: name))
    _ = try await source.read(offset: 0, maxLength: 10)
    await source.invalidate()
    let error = await failure(of: source)
    XCTAssertEqual(error, .interrupted)
  }
}
