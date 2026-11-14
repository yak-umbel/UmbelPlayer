import Darwin
import XCTest
@testable import UmbelCore

final class UmbelRTPStreamSourceTests: XCTestCase {
  private let fast = UmbelRTPStreamSource.Configuration(connectTimeout: 4, stallTimeout: 4)

  private func rtsp(_ port: UInt16, _ path: String = "/stream") -> URL {
    URL(string: "rtsp://127.0.0.1:\(port)\(path)")!
  }

  private func transportStream() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/live_stream.ts"))
  }

  private func failure(of source: UmbelRTPStreamSource) async -> UmbelError? {
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

  /// Reads what the engine would from the source: tracks, then packets.
  private func demux(_ source: UmbelRTPStreamSource, packets wanted: Int) async throws -> (
    tracks: [UmbelTrack], packets: Int, seekable: Bool
  ) {
    let demux = DemuxSession(source: source)
    try await demux.open()
    let tracks = await demux.tracks
    let seekable = await demux.isSeekable
    var packets = 0
    while packets < wanted, try await demux.nextPacket() != nil { packets += 1 }
    await demux.close()
    return (tracks, packets, seekable)
  }

  // ── Repackaged, and read back ───────────────────────

  func testRTSPSoundIsRepackagedAndTheEngineReadsItBack() async throws {
    let server = try LoopbackRTSP.serve(
      sdp: LoopbackRTSP.sdp(media: "m=audio 0 RTP/AVP 0"), packets: LoopbackRTSP.silentMuLaw(packets: 100))
    let source = try UmbelRTPStreamSource(url: rtsp(server.port), configuration: fast)
    let read = try await demux(source, packets: 40)
    XCTAssertEqual(read.tracks.map(\.kind), [.audio])
    XCTAssertFalse(read.seekable)
    XCTAssertEqual(read.packets, 40)
    await source.invalidate()
  }

  func testRTSPCarryingATransportStreamGivesPictureAndSound() async throws {
    let server = try LoopbackRTSP.serve(
      sdp: LoopbackRTSP.sdp(media: "m=video 0 RTP/AVP 33"),
      packets: LoopbackRTSP.transportStream(try transportStream()))
    let source = try UmbelRTPStreamSource(url: rtsp(server.port), configuration: fast)
    let read = try await demux(source, packets: 30)
    XCTAssertTrue(read.tracks.contains { $0.kind == .video })
    XCTAssertTrue(read.tracks.contains { $0.kind == .audio })
    XCTAssertFalse(read.seekable)
    XCTAssertEqual(read.packets, 30)
    await source.invalidate()
  }

  func testRTPDatagramsCarryingATransportStreamAreRepackaged() async throws {
    let port = LoopbackTCPServer.unusedPort(type: SOCK_DGRAM)
    let sender = LoopbackRTPSender(port: port, transportStream: try transportStream())
    defer { sender.stop() }
    let source = try UmbelRTPStreamSource(url: URL(string: "rtp://127.0.0.1:\(port)")!, configuration: fast)
    let read = try await demux(source, packets: 30)
    XCTAssertTrue(read.tracks.contains { $0.kind == .video })
    XCTAssertTrue(read.tracks.contains { $0.kind == .audio })
    XCTAssertEqual(read.packets, 30)
    await source.invalidate()
  }

  /// H.264 and AAC as a camera sends them, through a real RTSP server.
  func testRTSPFromARealServerIsRepackagedAndTheEngineReadsItBack() async throws {
    let port = try LocalMediaMTX.publishing(path: "live/test") { stop in addTeardownBlock(stop) }
    // The stream has to be published before it can be asked for: try again.
    var read: (tracks: [UmbelTrack], packets: Int, seekable: Bool)?
    for _ in 0..<40 where read == nil {
      let source = try UmbelRTPStreamSource(url: rtsp(port, "/live/test"), configuration: fast)
      do {
        read = try await demux(source, packets: 60)
      } catch {
        await source.invalidate()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    let got = try XCTUnwrap(read, "the server never came up")
    XCTAssertTrue(got.tracks.contains { $0.kind == .video })
    XCTAssertTrue(got.tracks.contains { $0.kind == .audio })
    XCTAssertFalse(got.seekable)
    XCTAssertEqual(got.packets, 60)
  }

  // ── Failing ─────────────────────────────────────────

  func testNothingListeningIsASourceFailureAtOnce() async throws {
    let port = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let source = try UmbelRTPStreamSource(url: rtsp(port), configuration: fast)
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    guard case .sourceUnavailable? = error else { return XCTFail("\(String(describing: error))") }
    XCTAssertLessThan(took, 3)
  }

  /// A peer that accepts and never answers: the connect deadline ends it,
  /// and nothing of the address, which may carry a token, is in the error.
  func testAPeerThatNeverAnswersTimesOutAtTheConnectDeadline() async throws {
    let release = DispatchSemaphore(value: 0)
    let server = try LoopbackTCPServer { _ in _ = release.wait(timeout: .now() + 5) }
    defer { release.signal() }
    let source = try UmbelRTPStreamSource(
      url: rtsp(server.port, "/stream?token=secret-token"),
      configuration: .init(connectTimeout: 0.5, stallTimeout: 5))
    var error: UmbelError?
    let took = await seconds { error = await self.failure(of: source) }
    XCTAssertEqual(error, .sourceUnavailable(detail: "connection timed out"))
    XCTAssertGreaterThan(took, 0.4)
    XCTAssertLessThan(took, 3)
    let words = "\(String(describing: error)) \(error?.errorDescription ?? "")"
    XCTAssertFalse(words.contains("secret-token"))
    XCTAssertFalse(words.contains("127.0.0.1"))
  }

  func testAStreamThatStopsComingIsAStallNotAHang() async throws {
    let server = try LoopbackRTSP.serve(
      sdp: LoopbackRTSP.sdp(media: "m=audio 0 RTP/AVP 0"), packets: LoopbackRTSP.silentMuLaw(packets: 100))
    let source = try UmbelRTPStreamSource(
      url: rtsp(server.port), configuration: .init(connectTimeout: 4, stallTimeout: 0.7))
    var failed: UmbelError?
    // Read until it stops coming: everything sent first, then silence.
    let took = await seconds {
      do {
        while true { _ = try await source.readNext(maxLength: 1 << 16) }
      } catch {
        failed = error as? UmbelError
      }
    }
    XCTAssertEqual(failed, .sourceUnavailable(detail: "no data received"))
    XCTAssertLessThan(took, 6)
    await source.invalidate()
  }

  // ── Giving up ───────────────────────────────────────

  func testInvalidatingEndsTheReadWaitingAndLetsTheConnectionGo() async throws {
    let closed = Seen()
    let server = try LoopbackRTSP.serve(
      sdp: LoopbackRTSP.sdp(media: "m=audio 0 RTP/AVP 0"), packets: LoopbackRTSP.silentMuLaw(packets: 100),
      onEnd: { closed.set() })
    let source = try UmbelRTPStreamSource(
      url: rtsp(server.port), configuration: .init(connectTimeout: 4, stallTimeout: 10))
    // Take what there is, so that the next read waits.
    var bytes = 0
    while bytes < 1 { bytes += try await source.readNext(maxLength: 1 << 16).count }
    let waiting = Task { () -> UmbelError? in
      do {
        while true { _ = try await source.readNext(maxLength: 1 << 16) }
      } catch {
        return error as? UmbelError
      }
    }
    try await Task.sleep(nanoseconds: 1_200_000_000)
    let took = await seconds { await source.invalidate() }
    let error = await waiting.value
    XCTAssertEqual(error, .interrupted)
    XCTAssertLessThan(took, 1)
    let sawClose = await closed.waitUntilSet()
    XCTAssertTrue(sawClose, "the peer saw the connection close")
  }

  // ── What is accepted ────────────────────────────────

  func testOnlyRTSPAndRTPAddressesAreAccepted() throws {
    let refused = [
      ("rtmp://h/a/b", "rtmp"), ("udp://127.0.0.1:1", "udp"), ("tcp://127.0.0.1:1", "tcp"), ("http://h/s", "http"),
      ("file:///etc/hosts", "file"), ("rtsps://h/s", "rtsps"), ("mmsh://h/s", "mmsh"), ("foo/bar", ""),
    ]
    for (text, scheme) in refused {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try UmbelRTPStreamSource(url: url), text) {
        XCTAssertEqual($0 as? UmbelError, .unsupportedScheme(scheme), text)
      }
    }
    for text in ["rtsp://h/s", "RTSP://h/s?token=x", "rtp://127.0.0.1:5004"] {
      XCTAssertNoThrow(try UmbelRTPStreamSource(url: try XCTUnwrap(URL(string: text))), text)
    }
  }

  /// An RTSP address's query is the server's own. An RTP address is a socket:
  /// the options FFmpeg reads out of it are limited as a UDP address's are.
  func testRTPAddressOptionsOutsideTheListAreRefused() throws {
    for text in ["rtp://127.0.0.1:5004?listen=1", "rtp://127.0.0.1:5004?connect=1", "rtp://127.0.0.1:5004?ttl=1"] {
      XCTAssertThrowsError(try UmbelRTPStreamSource(url: try XCTUnwrap(URL(string: text))), text) {
        guard case .sourceUnavailable? = $0 as? UmbelError else { return XCTFail("\($0)") }
      }
    }
    for text in ["rtp://127.0.0.1:5004?pkt_size=1316", "rtsp://h/s?listen=1&token=x"] {
      XCTAssertNoThrow(try UmbelRTPStreamSource(url: try XCTUnwrap(URL(string: text))), text)
    }
  }

  /// The other way: the sources that read bytes do not take these.
  func testTheByteSourcesRefuseRTSPAndRTP() throws {
    for text in ["rtsp://h/s", "rtp://127.0.0.1:5004"] {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertThrowsError(try UmbelNetworkStreamSource(url: url), text) {
        XCTAssertEqual($0 as? UmbelError, .unsupportedScheme(url.scheme ?? ""), text)
      }
    }
  }
}

private final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() { lock.lock(); value = true; lock.unlock() }

  var isSet: Bool {
    lock.lock(); defer { lock.unlock() }
    return value
  }

  func waitUntilSet(seconds: Double = 3) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if isSet { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return isSet
  }
}
