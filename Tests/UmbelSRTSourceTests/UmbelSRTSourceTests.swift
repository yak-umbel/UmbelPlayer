import Foundation
import XCTest
@testable import UmbelCore
@testable import UmbelSRTSource

final class UmbelSRTSourceTests: XCTestCase {
  private let fast = UmbelSRTSource.Configuration(connectTimeout: 3, stallTimeout: 3)

  private func address(_ port: UInt16, _ query: String = "") -> URL {
    URL(string: "srt://127.0.0.1:\(port)\(query)")!
  }

  private func transportStream() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Tests/Fixtures/live_stream.ts"))
  }

  /// Numbered messages: a reader can tell what it got, and whether it is whole.
  private func numbered(messages: Int) -> Data {
    var data = Data()
    for index in 0..<messages { data.append(Data(repeating: UInt8(index % 250 + 1), count: SRTTestPeer.messageSize)) }
    return data
  }

  private func read(_ source: UmbelSRTSource, bytes wanted: Int) async throws -> Data {
    var all = Data()
    while all.count < wanted { all += try await source.readNext(maxLength: 1 << 16) }
    return all
  }

  private func failure(of source: UmbelSRTSource) async -> UmbelError? {
    do {
      _ = try await source.readNext(maxLength: 16)
      return nil
    } catch {
      return error as? UmbelError
    }
  }

  private func seconds(_ body: () async -> Void) async -> Double {
    let start = ContinuousClock.now
    await body()
    let span = ContinuousClock.now - start
    return Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
  }

  // ── Reading ─────────────────────────────────────────

  func testMessagesFromAPeerAreReadInOrder() async throws {
    let payload = numbered(messages: 40)
    let peer = try SRTTestPeer(payload: payload)
    let source = try UmbelSRTSource(url: address(peer.port), configuration: fast)
    let got = try await read(source, bytes: payload.count)
    XCTAssertEqual(got, payload)
    let length = await source.contentLength
    XCTAssertNil(length)
    await source.invalidate()
  }

  func testADemuxerReadsATransportStreamOverSRTAndSaysItCannotSeek() async throws {
    let peer = try SRTTestPeer(payload: try transportStream())
    let source = try UmbelSRTSource(url: address(peer.port), configuration: fast)
    let demux = DemuxSession(source: source)
    try await demux.open()
    let tracks = await demux.tracks
    XCTAssertTrue(tracks.contains { $0.kind == .video })
    XCTAssertTrue(tracks.contains { $0.kind == .audio })
    let seekable = await demux.isSeekable
    XCTAssertFalse(seekable)
    var packets = 0
    while packets < 30, try await demux.nextPacket() != nil { packets += 1 }
    XCTAssertEqual(packets, 30)
    await demux.close()
    await source.invalidate()
  }

  // ── Encryption ──────────────────────────────────────

  func testAnEncryptedStreamIsReadWithTheRightPassphrase() async throws {
    let payload = numbered(messages: 20)
    let peer = try SRTTestPeer(payload: payload, passphrase: "correct horse battery")
    var configuration = fast
    configuration.passphrase = "correct horse battery"
    let source = try UmbelSRTSource(url: address(peer.port), configuration: configuration)
    let got = try await read(source, bytes: payload.count)
    XCTAssertEqual(got, payload, "decrypted, whole and in order")
    await source.invalidate()
  }

  func testAPassphraseInTheAddressDoesTheSame() async throws {
    let payload = numbered(messages: 10)
    let peer = try SRTTestPeer(payload: payload, passphrase: "correct horse battery")
    let source = try UmbelSRTSource(
      url: address(peer.port, "?passphrase=correct%20horse%20battery"), configuration: fast)
    let got = try await read(source, bytes: payload.count)
    XCTAssertEqual(got, payload)
    await source.invalidate()
  }

  /// A peer that wants a secret does not take a caller with the wrong one, or
  /// none; and what is said of it holds neither the secret nor the address.
  func testTheWrongPassphraseIsRefusedWithoutSayingWhat() async throws {
    let peer = try SRTTestPeer(payload: numbered(messages: 5), passphrase: "correct horse battery")
    var configuration = fast
    configuration.passphrase = "wrong wrong wrong"
    let source = try UmbelSRTSource(url: address(peer.port), configuration: configuration)
    let error = await failure(of: source)
    guard case .sourceUnavailable(let detail)? = error else { return XCTFail("\(String(describing: error))") }
    XCTAssertTrue(detail.hasPrefix("connection rejected"), detail)
    for secret in ["wrong wrong wrong", "correct horse battery", "127.0.0.1", "\(peer.port)"] {
      XCTAssertFalse(detail.contains(secret), "\(secret) is in \(detail)")
    }
    await source.invalidate()
  }

  func testNoPassphraseToAnEncryptedPeerIsRefused() async throws {
    let peer = try SRTTestPeer(payload: numbered(messages: 5), passphrase: "correct horse battery")
    let source = try UmbelSRTSource(url: address(peer.port), configuration: fast)
    let error = await failure(of: source)
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
    await source.invalidate()
  }

  // ── What the library says on its own ────────────────

  /// What the process writes to standard error while `body` runs. SRT's own
  /// lines are told apart by their area tag, so that a line from anything
  /// else sharing the descriptor cannot fail a test of ours.
  private func standardError(during body: () async throws -> Void) async throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("srt-stderr-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: file) }
    let descriptor = open(file.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    let saved = dup(STDERR_FILENO)
    dup2(descriptor, STDERR_FILENO)
    close(descriptor)
    var failure: Error?
    do { try await body() } catch { failure = error }
    dup2(saved, STDERR_FILENO)
    close(saved)
    if let failure { throw failure }
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").filter { $0.contains(":SRT.") }.joined(separator: "\n")
  }

  /// SRT's library writes what it has to say to standard error, to an app
  /// that never asked: warnings about reads that find nothing yet, and errors
  /// about handshakes it refuses, a few lines a second on a live stream. The
  /// host is told of a failure by the error it is thrown, not by that.
  func testTheLibraryWritesNothingToStandardErrorWhetherTheStreamPlaysOrIsRefused() async throws {
    let said = try await standardError {
      let payload = numbered(messages: 40)
      let peer = try SRTTestPeer(payload: payload)
      let source = try UmbelSRTSource(url: address(peer.port), configuration: fast)
      _ = try await read(source, bytes: payload.count)
      await source.invalidate()
      peer.stop()

      let guarded = try SRTTestPeer(payload: numbered(messages: 5), passphrase: "correct horse battery")
      var wrong = fast
      wrong.passphrase = "wrong wrong wrong"
      let refused = try UmbelSRTSource(url: address(guarded.port), configuration: wrong)
      _ = await failure(of: refused)
      await refused.invalidate()
      guarded.stop()
    }
    XCTAssertEqual(said, "", "SRT wrote to standard error")
  }

  // ── Failing ─────────────────────────────────────────

  func testNobodyThereIsASourceFailureAtTheConnectDeadline() async throws {
    let peer = try SRTTestPeer(payload: Data())
    let port = peer.port
    peer.stop()
    let source = try UmbelSRTSource(url: address(port), configuration: .init(connectTimeout: 1, stallTimeout: 5))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
    XCTAssertLessThan(took, 6)
    await source.invalidate()
  }

  func testAPeerThatStopsSendingIsAStallNotAHang() async throws {
    let payload = numbered(messages: 5)
    let peer = try SRTTestPeer(payload: payload)
    let source = try UmbelSRTSource(url: address(peer.port), configuration: .init(connectTimeout: 3, stallTimeout: 0.7))
    _ = try await read(source, bytes: payload.count)
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "no data received"))
    XCTAssertLessThan(took, 4)
    await source.invalidate()
  }

  /// SRT does not say whether a peer finished or was lost, and for a live
  /// stream the second is what must be told.
  func testAPeerThatGoesIsALostStreamNotAnEnd() async throws {
    let payload = numbered(messages: 5)
    let peer = try SRTTestPeer(payload: payload, closeAfterSending: true)
    let source = try UmbelSRTSource(url: address(peer.port), configuration: fast)
    var failed: UmbelError?
    do {
      while true { _ = try await source.readNext(maxLength: 1 << 16) }
    } catch {
      failed = error as? UmbelError
    }
    guard case .sourceUnavailable? = failed else { return XCTFail("\(String(describing: failed))") }
    await source.invalidate()
  }

  // ── Giving up ───────────────────────────────────────

  func testInvalidatingEndsTheReadWaitingAndLetsTheConnectionGo() async throws {
    let payload = numbered(messages: 3)
    let peer = try SRTTestPeer(payload: payload)
    let source = try UmbelSRTSource(url: address(peer.port), configuration: .init(connectTimeout: 3, stallTimeout: 20))
    _ = try await read(source, bytes: payload.count)
    let waiting = Task { try await source.readNext(maxLength: 1 << 16) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let took = await seconds { await source.invalidate() }
    do {
      _ = try await waiting.value
      XCTFail("an invalidated source gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(took, 2)
    for _ in 0..<300 where !peer.callerHasGone { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(peer.callerHasGone, "the peer saw the caller go")
  }

  func testReleasingTheSourceLetsTheConnectionGo() async throws {
    let payload = numbered(messages: 3)
    let peer = try SRTTestPeer(payload: payload)
    do {
      let source = try UmbelSRTSource(url: address(peer.port), configuration: fast)
      _ = try await read(source, bytes: payload.count)
    }
    for _ in 0..<300 where !peer.callerHasGone { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertTrue(peer.callerHasGone, "the peer saw the caller go")
  }

  // ── What is accepted ────────────────────────────────

  func testOnlySRTAddressesWithAPortAreAccepted() throws {
    for (text, scheme) in [("rtmp://h:1/a/b", "rtmp"), ("udp://h:1", "udp"), ("http://h:1/s", "http"), ("foo/bar", "")] {
      XCTAssertThrowsError(try UmbelSRTSource(url: try XCTUnwrap(URL(string: text))), text) {
        XCTAssertEqual($0 as? UmbelError, .unsupportedScheme(scheme), text)
      }
    }
    XCTAssertThrowsError(try UmbelSRTSource(url: try XCTUnwrap(URL(string: "srt://h")))) {
      guard case .sourceUnavailable? = $0 as? UmbelError else { return XCTFail("\($0)") }
    }
    for text in ["srt://h:9000", "SRT://h:9000?latency=200&streamid=cam1", "srt://[::1]:9000"] {
      XCTAssertNoThrow(try UmbelSRTSource(url: try XCTUnwrap(URL(string: text))), text)
    }
  }

  /// `mode=listener` makes the player open a port and wait for a peer: not
  /// something an address may ask for.
  func testAddressOptionsOutsideTheListAreRefused() throws {
    for text in ["srt://h:1?mode=listener", "srt://h:1?MODE=rendezvous", "srt://h:1?latency=200&oheadbw=90", "srt://h:1?adapter=en0"] {
      XCTAssertThrowsError(try UmbelSRTSource(url: try XCTUnwrap(URL(string: text))), text) {
        guard case .sourceUnavailable? = $0 as? UmbelError else { return XCTFail("\($0)") }
      }
    }
  }

  func testAPassphraseOfTheWrongLengthIsRefusedBeforeAnythingIsOpened() throws {
    for passphrase in ["short", String(repeating: "x", count: 80)] {
      var configuration = UmbelSRTSource.Configuration()
      configuration.passphrase = passphrase
      XCTAssertThrowsError(try UmbelSRTSource(url: try XCTUnwrap(URL(string: "srt://h:1")), configuration: configuration)) {
        guard case .sourceUnavailable(let detail)? = $0 as? UmbelError else { return XCTFail("\($0)") }
        XCTAssertFalse(detail.contains(passphrase), "the passphrase is not in what is said of it")
      }
    }
  }
}
