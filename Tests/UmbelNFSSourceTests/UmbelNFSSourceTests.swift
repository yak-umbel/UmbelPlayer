import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelNFSSource

final class UmbelNFSSourceTests: XCTestCase {
  private var server: LoopbackNFSServer!
  private var silent: SilentServer?
  private var sources: [UmbelNFSSource] = []
  private let content = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })

  override func setUpWithError() throws {
    server = try LoopbackNFSServer()
  }

  override func tearDown() async throws {
    for source in sources { await source.invalidate() }
    sources = []
    server?.stop()
    silent?.stop()
  }

  /// `nfs://127.0.0.1:port/path`, with the MOUNT service on the same port, as the one server has both.
  private func url(_ path: String, port: UInt16? = nil, query: String = "") -> URL {
    let port = port ?? server.port
    return URL(string: "nfs://127.0.0.1:\(port)\(path)?mountport=\(port)\(query)")!
  }

  private func source(
    _ url: URL, connectTimeout: TimeInterval = 10, stallTimeout: TimeInterval = 10, userID: Int? = nil, groupID: Int? = nil
  ) throws -> UmbelNFSSource {
    let made = try UmbelNFSSource(
      url: url,
      configuration: .init(connectTimeout: connectTimeout, stallTimeout: stallTimeout, userID: userID, groupID: groupID))
    sources.append(made)
    return made
  }

  private func readAll(_ source: UmbelNFSSource, chunk: Int = 400_000) async throws -> Data {
    var all = Data()
    while true {
      let piece = try await source.read(offset: Int64(all.count), maxLength: chunk)
      if piece.isEmpty { return all }
      all.append(piece)
    }
  }

  private func failure(of source: UmbelNFSSource, offset: Int64 = 0) async -> UmbelError? {
    do {
      _ = try await source.read(offset: offset, maxLength: 1_000)
      XCTFail("a read went through")
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  // ── Reading ─────────────────────────────────────────

  func testAFileIsReadWholeInPiecesAndItsLengthIsKnown() async throws {
    try server.serve("movie.bin", content)
    let source = try source(url("/media/movie.bin"))
    let length = await source.contentLength
    XCTAssertEqual(length, Int64(content.count))
    let all = try await readAll(source)
    XCTAssertEqual(all.count, content.count)
    XCTAssertEqual(all, content)
  }

  func testAReadFromAnywhereGivesTheBytesThereInAnyOrder() async throws {
    try server.serve("movie.bin", content)
    let source = try source(url("/media/movie.bin"))
    let middle = try await source.read(offset: 1_000_000, maxLength: 4_096)
    XCTAssertEqual(middle, content[1_000_000..<1_004_096] as Data)
    let next = try await source.read(offset: 1_000_000 + Int64(middle.count), maxLength: 4_096)
    XCTAssertEqual(next, content[(1_000_000 + middle.count)..<(1_000_000 + middle.count + next.count)] as Data)
    let back = try await source.read(offset: 10, maxLength: 100)
    XCTAssertEqual(back, content[10..<(10 + back.count)] as Data)
  }

  func testAReadAtOrPastTheEndIsEmpty() async throws {
    try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(url("/media/small.bin"))
    let tail = try await source.read(offset: 90, maxLength: 1_000)
    XCTAssertEqual(tail.count, 10)
    let atEnd = try await source.read(offset: 100, maxLength: 10)
    XCTAssertTrue(atEnd.isEmpty)
    let past = try await source.read(offset: 5_000, maxLength: 10)
    XCTAssertTrue(past.isEmpty)
  }

  func testAFileInASubfolderIsReadWhenTheExportIsSaid() async throws {
    try server.serve("shows/s 1/a file.bin", Data(repeating: 9, count: 50))
    let source = try source(url("/media/shows/s%201/a%20file.bin", query: "&export=/media"))
    let data = try await source.read(offset: 0, maxLength: 100)
    XCTAssertEqual(data, Data(repeating: 9, count: 50))
  }

  func testOnlyWhatReadingNeedsIsAskedOfTheServer() async throws {
    try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(url("/media/small.bin"))
    _ = try await source.read(offset: 0, maxLength: 10)
    let called = Set(server.procedures)
    XCTAssertTrue(called.isSuperset(of: ["MOUNT3 1", "NFS3 3", "NFS3 6"]), "\(called)")
    // WRITE, CREATE, REMOVE, RENAME and the other calls that change anything.
    for changing in [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 21] {
      XCTAssertFalse(called.contains("NFS3 \(changing)"), "NFS3 \(changing) was called")
    }
  }

  // ── Who it says it is ───────────────────────────────

  func testTheUserAndGroupTheServerIsToldAreTheOnesGiven() async throws {
    try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(url("/media/small.bin"), userID: 1234, groupID: 5678)
    _ = try await source.read(offset: 0, maxLength: 10)
    let seen = try XCTUnwrap(server.lastCredentials)
    XCTAssertEqual(seen.uid, 1234)
    XCTAssertEqual(seen.gid, 5678)
  }

  // ── Failures ────────────────────────────────────────

  func testAFileAnExportAndAServerThatRefusesAreSaidSoWithoutTheirNames() async throws {
    try server.serve("small.bin", Data(repeating: 7, count: 100))
    server.refuseMounting("/media/refused")
    let cases: [(String, URL, String)] = [
      ("file", url("/media/not-there-at-all.bin"), "file not found or not readable"),
      ("export", url("/elsewhere/small.bin"), "export not found or not permitted"),
      ("refused", url("/media/refused/small.bin"), "access denied"),
    ]
    for (what, address, expected) in cases {
      let source = try source(address)
      let error = await failure(of: source)
      XCTAssertEqual(error, .sourceUnavailable(detail: expected), what)
      for name in ["not-there", "elsewhere", "refused", "small.bin", "127.0.0.1"] {
        XCTAssertFalse("\(String(describing: error))".contains(name), "\(what): \(name)")
      }
    }
  }

  // ── Silence, cancelling ─────────────────────────────

  func testAServerThatNeverAnswersIsGivenUpOnAtTheConnectDeadline() async throws {
    let quiet = try SilentServer()
    silent = quiet
    let source = try source(url("/media/f.bin", port: quiet.port), connectTimeout: 0.6)
    let began = Date()
    let error = await failure(of: source)
    XCTAssertEqual(error, .sourceUnavailable(detail: "connection timed out"))
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
  }

  func testACancelledReadGivesUpAtOnceWhateverTheDeadline() async throws {
    let quiet = try SilentServer()
    silent = quiet
    let source = try source(url("/media/f.bin", port: quiet.port), connectTimeout: 60)
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

  func testATransferThatGoesQuietIsGivenUpOnAtTheStallDeadlineAndTheNextReadStartsOver() async throws {
    try server.serve("movie.bin", content)
    let source = try source(url("/media/movie.bin"), stallTimeout: 0.8)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    server.hold(true)
    let began = Date()
    let error = await failure(of: source, offset: 1_200_000)
    XCTAssertEqual(error, .sourceUnavailable(detail: "no data received"))
    XCTAssertLessThan(Date().timeIntervalSince(began), 4)
    server.hold(false)
    let again = try await source.read(offset: 1_200_000, maxLength: 1_000)
    XCTAssertEqual(again, content[1_200_000..<(1_200_000 + again.count)] as Data)
    XCTAssertFalse(again.isEmpty)
  }

  func testAfterACancelledReadTheNextOneConnectsAgain() async throws {
    try server.serve("movie.bin", content)
    let source = try source(url("/media/movie.bin"), stallTimeout: 60)
    _ = try await source.read(offset: 0, maxLength: 1_000)
    server.hold(true)
    let task = Task { try await source.read(offset: 1_200_000, maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    server.hold(false)
    let again = try await source.read(offset: 1_200_000, maxLength: 1_000)
    XCTAssertFalse(again.isEmpty)
    XCTAssertEqual(again, content[1_200_000..<(1_200_000 + again.count)] as Data)
    XCTAssertEqual(server.procedures.filter { $0 == "MOUNT3 1" }.count, 2, "mounted again, the old connection not trusted")
  }

  func testAReadAfterInvalidatingIsInterrupted() async throws {
    try server.serve("small.bin", Data(repeating: 7, count: 100))
    let source = try source(url("/media/small.bin"))
    _ = try await source.read(offset: 0, maxLength: 10)
    await source.invalidate()
    let error = await failure(of: source)
    XCTAssertEqual(error, .interrupted)
  }
}
