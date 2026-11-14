import CoreMedia
import Darwin
import XCTest
@testable import UmbelCore

private final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func set() { lock.lock(); count += 1; lock.unlock() }

  var isSet: Bool {
    lock.lock(); defer { lock.unlock() }
    return count > 0
  }

  func waitUntilSet(seconds: Double = 3) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if isSet { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return isSet
  }
}

final class UmbelFTPSourceTests: XCTestCase {
  private let fast = UmbelFTPSource.Configuration(connectTimeout: 3, stallTimeout: 3)
  private let pattern = Data((0..<100_000).map { UInt8($0 % 251) })

  private func address(_ port: UInt16, _ path: String = "/file") -> URL {
    URL(string: "ftp://127.0.0.1:\(port)\(path)")!
  }

  private func server(
    stallFirstTransferAfter: Int? = nil, silent: Bool = false, onControlEnd: @escaping @Sendable () -> Void = {}
  ) throws -> LoopbackFTPServer {
    try LoopbackFTPServer(
      behaviour: .init(content: pattern, stallFirstTransferAfter: stallFirstTransferAfter, silent: silent),
      onControlEnd: onControlEnd)
  }

  private func seconds(_ body: () async -> Void) async -> Double {
    let start = ContinuousClock.now
    await body()
    let span = ContinuousClock.now - start
    return Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
  }

  private func failure(of source: UmbelFTPSource, offset: Int64 = 0) async -> UmbelError? {
    do {
      _ = try await source.read(offset: offset, maxLength: 16)
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  // ── Reading ─────────────────────────────────────────

  func testAnyPartOfTheFileCanBeReadInAnyOrder() async throws {
    let ftp = try server()
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: fast)
    let start = try await source.read(offset: 0, maxLength: 100)
    XCTAssertEqual(start, pattern.prefix(100))
    let middle = try await source.read(offset: 50_000, maxLength: 100)
    XCTAssertEqual(middle, pattern.subdata(in: 50_000..<50_100))
    let back = try await source.read(offset: 1_000, maxLength: 100)
    XCTAssertEqual(back, pattern.subdata(in: 1_000..<1_100), "reading back again is a read from there")
    let next = try await source.read(offset: 1_100, maxLength: 100)
    XCTAssertEqual(next, pattern.subdata(in: 1_100..<1_200), "reading on goes on from where it was")
    await source.invalidate()
  }

  func testTheEndOfTheFileIsTheEnd() async throws {
    let ftp = try server()
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: fast)
    let last = try await source.read(offset: 99_950, maxLength: 1_000)
    XCTAssertEqual(last, pattern.subdata(in: 99_950..<100_000))
    let after = try await source.read(offset: 100_000, maxLength: 10)
    XCTAssertEqual(after, Data(), "nothing is at the end")
    await source.invalidate()
  }

  func testTheLengthComesFromTheServer() async throws {
    let ftp = try server()
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: fast)
    let length = await source.contentLength
    XCTAssertEqual(length, 100_000)
    await source.invalidate()
  }

  /// Through the engine, as a session would: a file off a server that can be
  /// seeked in, and played from anywhere.
  func testTheEngineSeeksInAFileOffAnFTPServer() async throws {
    let movie = try Data(contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/seek_grid.mp4"))
    let ftp = try LoopbackFTPServer(behaviour: .init(content: movie))
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: fast)
    let demux = DemuxSession(source: source)
    try await demux.open()
    let seekable = await demux.isSeekable
    XCTAssertTrue(seekable)
    let duration = await demux.duration
    XCTAssertTrue(duration.isNumeric)
    try await demux.seek(to: CMTime(seconds: 1, preferredTimescale: 600))
    var packets = 0
    while packets < 10, try await demux.nextPacket() != nil { packets += 1 }
    XCTAssertEqual(packets, 10)
    await demux.close()
    await source.invalidate()
  }

  // ── Failing ─────────────────────────────────────────

  func testAFileThatIsNotThereIsASourceFailure() async throws {
    let ftp = try server()
    let source = try UmbelFTPSource(url: address(ftp.port, "/missing"), configuration: fast)
    let error = await failure(of: source)
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
    await source.invalidate()
  }

  func testNothingListeningIsASourceFailureAtOnce() async throws {
    let port = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let source = try UmbelFTPSource(url: address(port), configuration: fast)
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
    XCTAssertLessThan(took, 3)
  }

  /// A server that accepts and never speaks is ended by the connect deadline,
  /// and a password in the address is nowhere in the error.
  func testAServerThatNeverSpeaksTimesOutAtTheConnectDeadline() async throws {
    let ftp = try server(silent: true)
    let url = URL(string: "ftp://user:secret-password@127.0.0.1:\(ftp.port)/file")!
    let source = try UmbelFTPSource(url: url, configuration: .init(connectTimeout: 0.5, stallTimeout: 5))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "connection timed out"))
    XCTAssertGreaterThan(took, 0.4)
    XCTAssertLessThan(took, 3)
    let words = "\(String(describing: error)) \(error?.errorDescription ?? "")"
    XCTAssertFalse(words.contains("secret-password"))
    XCTAssertFalse(words.contains("127.0.0.1"))
  }

  func testATransferThatStallsIsAStallNotAHang() async throws {
    let ftp = try server(stallFirstTransferAfter: 1_000)
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: .init(connectTimeout: 3, stallTimeout: 0.7))
    let first = try await source.read(offset: 0, maxLength: 4_000)
    XCTAssertEqual(first, pattern.prefix(1_000))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source, offset: 1_000) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "no data received"))
    XCTAssertLessThan(took, 5)
    await source.invalidate()
  }

  // ── Giving up ───────────────────────────────────────

  /// A read given up on is not the end of the source: the next read, from
  /// wherever, is served, on a connection made again.
  func testCancellingAReadDoesNotEndTheSource() async throws {
    let ftp = try server(stallFirstTransferAfter: 1_000)
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: .init(connectTimeout: 3, stallTimeout: 10))
    let first = try await source.read(offset: 0, maxLength: 4_000)
    XCTAssertEqual(first, pattern.prefix(1_000))
    let waiting = Task { try await source.read(offset: 1_000, maxLength: 4_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled read gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    let after = try await source.read(offset: 1_000, maxLength: 100)
    XCTAssertEqual(after, pattern.subdata(in: 1_000..<1_100))
    await source.invalidate()
  }

  /// A read given up on closes the connection it was on. One already asked
  /// for behind it must wait for that, not begin on a connection being closed.
  func testAReadQueuedBehindOneThatIsGivenUpOnIsStillServed() async throws {
    let ftp = try server(stallFirstTransferAfter: 1_000)
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: .init(connectTimeout: 3, stallTimeout: 10))
    _ = try await source.read(offset: 0, maxLength: 4_000)
    let given = Task { try await source.read(offset: 1_000, maxLength: 4_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let queued = Task { try await source.read(offset: 1_000, maxLength: 100) }
    try await Task.sleep(nanoseconds: 100_000_000)
    given.cancel()
    _ = try? await given.value
    let served = try await queued.value
    XCTAssertEqual(served, pattern.subdata(in: 1_000..<1_100))
    await source.invalidate()
  }

  func testInvalidatingEndsTheReadWaitingAndLetsTheConnectionGo() async throws {
    let ended = Seen()
    let ftp = try server(stallFirstTransferAfter: 1_000, onControlEnd: { ended.set() })
    let source = try UmbelFTPSource(url: address(ftp.port), configuration: .init(connectTimeout: 3, stallTimeout: 10))
    _ = try await source.read(offset: 0, maxLength: 4_000)
    let waiting = Task { try await source.read(offset: 1_000, maxLength: 4_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let took = await seconds { await source.invalidate() }
    do {
      _ = try await waiting.value
      XCTFail("an invalidated source gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(took, 2)
    let after = await failure(of: source)
    XCTAssertEqual(after, .interrupted)
    let sawEnd = await ended.waitUntilSet()
    XCTAssertTrue(sawEnd, "the server saw the connection go")
  }

  func testReleasingTheSourceLetsTheConnectionGo() async throws {
    let ended = Seen()
    let ftp = try server(onControlEnd: { ended.set() })
    do {
      let source = try UmbelFTPSource(url: address(ftp.port), configuration: fast)
      let first = try await source.read(offset: 0, maxLength: 100)
      XCTAssertEqual(first, pattern.prefix(100))
    }
    let sawEnd = await ended.waitUntilSet()
    XCTAssertTrue(sawEnd, "the server saw the connection go")
  }

  // ── What is accepted ────────────────────────────────

  func testOnlyFTPAddressesAreAccepted() throws {
    let refused = [
      ("http://h/f", "http"), ("rtmp://h/a/b", "rtmp"), ("sftp://h/f", "sftp"), ("ftps://h/f", "ftps"),
      ("file:///etc/hosts", "file"), ("foo/bar", ""),
    ]
    for (text, scheme) in refused {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try UmbelFTPSource(url: url), text) {
        XCTAssertEqual($0 as? UmbelError, .unsupportedScheme(scheme), text)
      }
    }
    for text in ["ftp://h/f", "FTP://user:pw@h:2121/dir/f"] {
      XCTAssertNoThrow(try UmbelFTPSource(url: try XCTUnwrap(URL(string: text))), text)
    }
  }
}
