import Darwin
import XCTest
@testable import UmbelCore

private final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock(); defer { lock.unlock() }
    return value
  }

  func set() { lock.lock(); value = true; lock.unlock() }

  func waitUntilSet(seconds: Double = 3) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if isSet { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return isSet
  }
}

final class UmbelNetworkStreamSourceTests: XCTestCase {
  private let fast = UmbelNetworkStreamSource.Configuration(connectTimeout: 2, stallTimeout: 2)

  private func address(_ scheme: String, _ port: UInt16, _ path: String = "") -> URL {
    URL(string: "\(scheme)://127.0.0.1:\(port)\(path)")!
  }

  private func readAll(_ source: UmbelNetworkStreamSource) async throws -> Data {
    var all = Data()
    while true {
      let next = try await source.readNext(maxLength: 1 << 16)
      if next.isEmpty { return all }
      all += next
    }
  }

  private func failure(of source: UmbelNetworkStreamSource) async -> UmbelError? {
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

  func testBytesFromATCPPeerComeInOrderAndTheEndIsTheEnd() async throws {
    let server = try LoopbackTCPServer { connection in
      connection.send(Data([1, 2, 3]))
      connection.send(Data([4, 5]))
    }
    let source = try UmbelNetworkStreamSource(url: address("tcp", server.port), configuration: fast)
    let all = try await readAll(source)
    XCTAssertEqual(all, Data([1, 2, 3, 4, 5]))
    let again = try await source.readNext(maxLength: 16)
    XCTAssertEqual(again, Data(), "the end stays the end")
    let length = await source.contentLength
    XCTAssertNil(length)
  }

  func testADemuxerReadsATransportStreamOffTheNetworkAndSaysItCannotSeek() async throws {
    let payload = try Data(contentsOf: Self.fixture("live_like.ts"))
    let server = try LoopbackTCPServer { $0.send(payload) }
    let source = try UmbelNetworkStreamSource(url: address("tcp", server.port), configuration: fast)
    let demux = DemuxSession(source: source)
    try await demux.open()
    let seekable = await demux.isSeekable
    XCTAssertFalse(seekable)
    var packets = 0
    while try await demux.nextPacket() != nil { packets += 1 }
    XCTAssertGreaterThan(packets, 0)
    await demux.close()
  }

  func testUDPDatagramsAreReadAsBytes() async throws {
    let port = LoopbackTCPServer.unusedPort(type: SOCK_DGRAM)
    let sender = LoopbackDatagramSender(port: port)
    defer { sender.stop() }
    let source = try UmbelNetworkStreamSource(url: address("udp", port), configuration: fast)
    let first = try await source.readNext(maxLength: 1 << 16)
    let second = try await source.readNext(maxLength: 1 << 16)
    for datagram in [first, second] {
      XCTAssertEqual(datagram.count, LoopbackDatagramSender.size)
      XCTAssertNotEqual(datagram.first, 0)
      XCTAssertEqual(Set(datagram).count, 1, "a whole datagram, from one send")
    }
    await source.invalidate()
  }

  // ── Failing ─────────────────────────────────────────

  func testAPeerThatResetsTheConnectionIsASourceFailureNotAnEnd() async throws {
    let server = try LoopbackTCPServer { connection in
      connection.send(Data([1, 2]))
      usleep(200_000)
      connection.reset()
    }
    let source = try UmbelNetworkStreamSource(url: address("tcp", server.port), configuration: fast)
    do {
      _ = try await readAll(source)
      XCTFail("a reset is not the end of the stream")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
      XCTAssertTrue(error.isRetryable)
    }
  }

  func testNothingListeningIsASourceFailureAtOnce() async throws {
    let port = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let source = try UmbelNetworkStreamSource(url: address("tcp", port), configuration: fast)
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
    XCTAssertLessThan(took, 2)
  }

  /// FFmpeg's own timeouts do not cover a peer that never answers the
  /// opening exchange: the deadline here does, and nothing of the address,
  /// which carries a token, is in the error.
  func testAPeerThatNeverAnswersTheHandshakeTimesOutAtTheConnectDeadline() async throws {
    let release = DispatchSemaphore(value: 0)
    let server = try LoopbackTCPServer { _ in _ = release.wait(timeout: .now() + 5) }
    defer { release.signal() }
    let url = address("rtmp", server.port, "/live/stream?token=secret-token")
    let source = try UmbelNetworkStreamSource(
      url: url, configuration: .init(connectTimeout: 0.5, stallTimeout: 5))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "connection timed out"))
    XCTAssertGreaterThan(took, 0.4)
    XCTAssertLessThan(took, 3)
    let words = "\(String(describing: error)) \(error?.errorDescription ?? "")"
    XCTAssertFalse(words.contains("secret-token"))
    XCTAssertFalse(words.contains("127.0.0.1"))
    XCTAssertFalse(words.contains("\(server.port)"))
  }

  func testAPeerThatStopsSendingIsAStallNotAHang() async throws {
    let release = DispatchSemaphore(value: 0)
    let server = try LoopbackTCPServer { connection in
      connection.send(Data([1, 2, 3]))
      _ = release.wait(timeout: .now() + 5)
    }
    defer { release.signal() }
    let source = try UmbelNetworkStreamSource(
      url: address("tcp", server.port), configuration: .init(connectTimeout: 2, stallTimeout: 0.5))
    let first = try await source.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1, 2, 3]))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "no data received"))
    XCTAssertGreaterThan(took, 0.4)
    XCTAssertLessThan(took, 3)
  }

  func testUDPWithNothingSentIsAStallNotAHang() async throws {
    let port = LoopbackTCPServer.unusedPort(type: SOCK_DGRAM)
    let source = try UmbelNetworkStreamSource(
      url: address("udp", port), configuration: .init(connectTimeout: 2, stallTimeout: 0.5))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "no data received"))
    XCTAssertLessThan(took, 3)
  }

  // ── Giving up ───────────────────────────────────────

  func testInvalidatingEndsTheReadWaitingAndLetsTheConnectionGo() async throws {
    let closed = Seen()
    let server = try LoopbackTCPServer { connection in
      connection.send(Data([1]))
      if connection.waitForPeerClose(timeout: 5) { closed.set() }
    }
    // A long stall timeout: only an interrupt can end the read in time.
    let source = try UmbelNetworkStreamSource(
      url: address("tcp", server.port), configuration: .init(connectTimeout: 2, stallTimeout: 10))
    let first = try await source.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1]))
    let waiting = Task { try await source.readNext(maxLength: 16) }
    try await Task.sleep(nanoseconds: 150_000_000)
    let took = await seconds { await source.invalidate() }
    do {
      _ = try await waiting.value
      XCTFail("an invalidated source gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(took, 1)
    let after = await failure(of: source)
    XCTAssertEqual(after, .interrupted)
    let sawClose = await closed.waitUntilSet()
    XCTAssertTrue(sawClose, "the peer saw the connection close")
  }

  func testCancellingAReadDoesNotEndTheStream() async throws {
    let goOn = DispatchSemaphore(value: 0)
    let server = try LoopbackTCPServer { connection in
      connection.send(Data([1]))
      _ = goOn.wait(timeout: .now() + 5)
      connection.send(Data([2, 3]))
      _ = connection.waitForPeerClose(timeout: 5)
    }
    let source = try UmbelNetworkStreamSource(url: address("tcp", server.port), configuration: fast)
    let first = try await source.readNext(maxLength: 16)
    XCTAssertEqual(first, Data([1]))
    let waiting = Task { try await source.readNext(maxLength: 16) }
    try await Task.sleep(nanoseconds: 150_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a cancelled read gives no bytes")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    goOn.signal()
    let next = try await source.readNext(maxLength: 16)
    XCTAssertEqual(next, Data([2, 3]))
    await source.invalidate()
  }

  /// A host that lets the source go without invalidating it has not left the
  /// connection open for good.
  func testReleasingTheSourceLetsTheConnectionGo() async throws {
    let closed = Seen()
    let server = try LoopbackTCPServer { connection in
      connection.send(Data([1]))
      if connection.waitForPeerClose(timeout: 5) { closed.set() }
    }
    do {
      let source = try UmbelNetworkStreamSource(
        url: address("tcp", server.port), configuration: .init(connectTimeout: 2, stallTimeout: 10))
      let first = try await source.readNext(maxLength: 16)
      XCTAssertEqual(first, Data([1]))
    }
    let sawClose = await closed.waitUntilSet()
    XCTAssertTrue(sawClose, "the peer saw the connection close")
  }

  // ── What is accepted ────────────────────────────────

  func testAddressesOutsideTheSchemeListAreRefusedBeforeAnythingIsOpened() throws {
    let refused = [
      ("rtsp://h/s", "rtsp"), ("http://h/s", "http"), ("https://h/s", "https"), ("file:///etc/hosts", "file"),
      ("mmsh://h/s", "mmsh"), ("mmst://h/s", "mmst"), ("ftp://h/s", "ftp"), ("vault://h/s", "vault"),
      ("foo/bar", ""),
    ]
    for (text, scheme) in refused {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try UmbelNetworkStreamSource(url: url), text) {
        XCTAssertEqual($0 as? UmbelError, .unsupportedScheme(scheme), text)
      }
    }
    for text in ["rtmp://h/a/b?x=1", "RTMPS://h/a", "rtmpt://h/a/b", "RTMPTS://h/a/b?x=1",
                 "udp://127.0.0.1:1234", "tcp://127.0.0.1:1234"] {
      XCTAssertNoThrow(try UmbelNetworkStreamSource(url: try XCTUnwrap(URL(string: text))), text)
    }
  }

  /// FFmpeg reads options out of an address: `listen=1` would make the
  /// player open a port and wait for a peer. Nothing outside a short list
  /// gets through, in any case; an RTMP address's query is the server's own.
  func testAddressOptionsOutsideTheListAreRefused() throws {
    for text in ["tcp://127.0.0.1:1?listen=1", "tcp://127.0.0.1:1?LISTEN=1", "udp://127.0.0.1:1?broadcast=1",
                 "udp://127.0.0.1:1?pkt_size=1316&listen=1", "tcp://127.0.0.1:1?timeout=1"] {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try UmbelNetworkStreamSource(url: url), text) {
        guard case .sourceUnavailable? = $0 as? UmbelError else { return XCTFail("\($0)") }
      }
    }
    for text in ["udp://127.0.0.1:1?pkt_size=1316", "udp://127.0.0.1:1?fifo_size=100000&overrun_nonfatal=1",
                 "rtmp://h/a/b?listen=1&token=x"] {
      XCTAssertNoThrow(try UmbelNetworkStreamSource(url: try XCTUnwrap(URL(string: text))), text)
    }
  }

  // ── A real RTMP server ──────────────────────────────

  /// Needs an `ffmpeg` to act as the server, as a developer machine has;
  /// without one the test says so rather than failing.
  func testRTMPFromALocalServerIsDemuxedAndCannotSeek() async throws {
    guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("no ffmpeg to serve a stream")
    }
    let port = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: ffmpeg)
    server.arguments = [
      "-hide_banner", "-loglevel", "quiet", "-re", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-c:v", "libx264", "-preset", "ultrafast",
      "-pix_fmt", "yuv420p", "-g", "25", "-c:a", "aac", "-t", "20", "-f", "flv", "-listen", "1",
      "rtmp://127.0.0.1:\(port)/live/test",
    ]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    addTeardownBlock { if server.isRunning { server.terminate() } }

    // The server takes one client and the source does not reconnect: try
    // again until the server is listening.
    var demux: DemuxSession?
    for _ in 0..<40 where demux == nil {
      let attempt = DemuxSession(source: try UmbelNetworkStreamSource(
        url: address("rtmp", port, "/live/test"), configuration: fast))
      do {
        try await attempt.open()
        demux = attempt
      } catch {
        await attempt.close()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    let opened = try XCTUnwrap(demux, "the server never came up")
    let tracks = await opened.tracks
    XCTAssertTrue(tracks.contains { $0.kind == .video })
    XCTAssertTrue(tracks.contains { $0.kind == .audio })
    let seekable = await opened.isSeekable
    XCTAssertFalse(seekable)
    var packets = 0
    while packets < 30, try await opened.nextPacket() != nil { packets += 1 }
    XCTAssertEqual(packets, 30)
    await opened.close()
  }

  /// RTMP carried in HTTP requests, through a tunnel, to a local server.
  /// Needs an `ffmpeg` to act as the RTMP server; without one the test says so.
  func testRTMPTunnelledOverHTTPIsDemuxedAndCannotSeek() async throws {
    guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("no ffmpeg to serve a stream")
    }
    let rtmpPort = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: ffmpeg)
    server.arguments = [
      "-hide_banner", "-loglevel", "quiet", "-re", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-c:v", "flv", "-g", "25",
      "-c:a", "aac", "-t", "20", "-f", "flv", "-listen", "1", "rtmp://127.0.0.1:\(rtmpPort)/live/test",
    ]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    addTeardownBlock { if server.isRunning { server.terminate() } }
    let tunnel = try LoopbackRTMPTunnel(upstreamPort: rtmpPort)
    addTeardownBlock { tunnel.stop() }

    // The server takes one client and the source does not reconnect: try
    // again until the server is listening.
    var demux: DemuxSession?
    for _ in 0..<40 where demux == nil {
      let attempt = DemuxSession(source: try UmbelNetworkStreamSource(
        url: address("rtmpt", tunnel.port, "/live/test"), configuration: fast))
      do {
        try await attempt.open()
        demux = attempt
      } catch {
        await attempt.close()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    let opened = try XCTUnwrap(demux, "the server never came up")
    let tracks = await opened.tracks
    XCTAssertTrue(tracks.contains { $0.kind == .video })
    XCTAssertTrue(tracks.contains { $0.kind == .audio })
    let seekable = await opened.isSeekable
    XCTAssertFalse(seekable)
    var packets = 0
    while packets < 30, try await opened.nextPacket() != nil { packets += 1 }
    XCTAssertEqual(packets, 30)
    await opened.close()
  }

  /// RTMPS to a real server whose certificate the system does not know. The
  /// certificate is trusted when it is handed over, and refused when it is
  /// not: there is no way to turn the check off.
  func testRTMPSChecksTheServersCertificate() async throws {
    let credentials = try LocalMediaMTX.selfSignedCertificate { stop in addTeardownBlock(stop) }
    let ports = try LocalMediaMTX.publishingWithRTMPS(
      path: "live/test", key: credentials.key, certificate: credentials.certificate
    ) { stop in addTeardownBlock(stop) }
    let url = address("rtmps", ports.rtmps, "/live/test")

    // With the certificate it is a server to trust.
    let trusted = UmbelNetworkStreamSource.Configuration(
      connectTimeout: 4, stallTimeout: 4, certificateAuthorityFile: credentials.certificate)
    var demux: DemuxSession?
    for _ in 0..<40 where demux == nil {
      let attempt = DemuxSession(source: try UmbelNetworkStreamSource(url: url, configuration: trusted))
      do {
        try await attempt.open()
        demux = attempt
      } catch {
        await attempt.close()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    let opened = try XCTUnwrap(demux, "the server never came up")
    let tracks = await opened.tracks
    XCTAssertTrue(tracks.contains { $0.kind == .video })
    XCTAssertTrue(tracks.contains { $0.kind == .audio })
    var packets = 0
    while packets < 30, try await opened.nextPacket() != nil { packets += 1 }
    XCTAssertEqual(packets, 30)
    await opened.close()

    // Without it, the same server, known to be there, is not.
    let source = try UmbelNetworkStreamSource(url: url, configuration: fast)
    let refused = await failure(of: source)
    guard case .sourceUnavailable? = refused else { return XCTFail("an unknown certificate was taken: \(String(describing: refused))") }
    await source.invalidate()
  }

  private static func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }
}
