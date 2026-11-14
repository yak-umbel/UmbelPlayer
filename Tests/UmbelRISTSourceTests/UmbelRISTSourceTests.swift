import Foundation
import LibRIST
import XCTest
@testable import UmbelCore
@testable import UmbelRISTSource

final class UmbelRISTSourceTests: XCTestCase {
  private var peers: [RISTTestPeer] = []
  private var sources: [UmbelRISTSource] = []

  override func tearDown() async throws {
    for source in sources { await source.invalidate() }
    for peer in peers { peer.stop() }
    sources = []
    peers = []
  }

  private func peer(
    profile: rist_profile = RIST_PROFILE_MAIN, secret: String? = nil, aesBits: Int32 = 128
  ) throws -> RISTTestPeer {
    let made = try RISTTestPeer(profile: profile, secret: secret, aesBits: aesBits)
    peers.append(made)
    return made
  }

  private func source(
    port: UInt16, query: String = "", configuration: UmbelRISTSource.Configuration? = nil
  ) throws -> UmbelRISTSource {
    let made = try UmbelRISTSource(
      url: URL(string: "rist://127.0.0.1:\(port)\(query)")!,
      configuration: configuration ?? .init(connectTimeout: 10, stallTimeout: 10, buffer: 100))
    sources.append(made)
    return made
  }

  /// At least `count` bytes of the stream, read in pieces of `chunk`.
  private func read(_ source: UmbelRISTSource, atLeast count: Int, chunk: Int = 100_000) async throws -> Data {
    var all = Data()
    while all.count < count { all.append(try await source.readNext(maxLength: chunk)) }
    return all
  }

  /// The first `count` whole payloads of what was read.
  private func whole(_ stream: Data, count: Int) -> Data {
    stream.prefix(count * RISTTestPeer.payloadSize)
  }

  private func assertTheStream(_ stream: Data, atLeast count: Int, file: StaticString = #filePath, line: UInt = #line) {
    let numbers = RISTTestPeer.numbers(in: whole(stream, count: count))
    XCTAssertNotNil(numbers, "what arrived is not the stream", file: file, line: line)
    guard let numbers else { return }
    XCTAssertEqual(numbers.count, count, file: file, line: line)
    XCTAssertEqual(numbers, Array(numbers[0]..<numbers[0] + UInt64(count)), "payloads were lost or out of order", file: file, line: line)
  }

  // ── Reading ─────────────────────────────────────────

  func testTheStreamArrivesWholeAndInOrder() async throws {
    let sender = try peer()
    let source = try source(port: sender.port)
    sender.send()
    let stream = try await read(source, atLeast: 300 * RISTTestPeer.payloadSize)
    assertTheStream(stream, atLeast: 300)
    let length = await source.contentLength
    XCTAssertNil(length, "a live stream has no length")
  }

  func testAReadSmallerThanAPayloadTakesItInPieces() async throws {
    let sender = try peer()
    let source = try source(port: sender.port)
    sender.send()
    var stream = Data()
    while stream.count < 100 * RISTTestPeer.payloadSize {
      let piece = try await source.readNext(maxLength: 100)
      XCTAssertLessThanOrEqual(piece.count, 100, "a read gives no more than it was asked for")
      stream.append(piece)
    }
    assertTheStream(stream, atLeast: 100)
  }

  /// The buffer is how long the receiver holds the stream back to ask again
  /// for what is lost, so it is how late the stream starts.
  func testTheRecoveryBufferDecidesHowLateTheStreamStarts() async throws {
    var firstByte: [Int: TimeInterval] = [:]
    for buffer in [100, 1_500] {
      let sender = try peer()
      // No buffer in the configuration, which would win over the address's.
      let source = try source(
        port: sender.port, query: "?buffer=\(buffer)", configuration: .init(connectTimeout: 10, stallTimeout: 10))
      sender.send()
      let began = Date()
      _ = try await source.readNext(maxLength: 1_000)
      firstByte[buffer] = Date().timeIntervalSince(began)
      sender.stop()
      await source.invalidate()
    }
    XCTAssertLessThan(try XCTUnwrap(firstByte[100]), 1.0)
    XCTAssertGreaterThan(try XCTUnwrap(firstByte[1_500]), 1.3)
  }

  // ── Encryption ──────────────────────────────────────

  func testAPassphraseOnBothSidesGivesTheStream() async throws {
    for bits in [Int32(128), 256] {
      let sender = try peer(secret: "a passphrase to share", aesBits: bits)
      let source = try source(
        port: sender.port, configuration: .init(connectTimeout: 10, stallTimeout: 10, buffer: 100, secret: "a passphrase to share", aesBits: Int(bits)))
      sender.send()
      let stream = try await read(source, atLeast: 100 * RISTTestPeer.payloadSize)
      assertTheStream(stream, atLeast: 100)
    }
  }

  func testAPassphraseWithCharactersAnAddressWouldSplitOnReachesTheLibraryAsItIs() async throws {
    let secret = "p&s=s/w?o#r d%1"
    let sender = try peer(secret: secret)
    let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let source = try source(port: sender.port, query: "?secret=\(encoded)&aes-type=128&buffer=100")
    sender.send()
    let stream = try await read(source, atLeast: 100 * RISTTestPeer.payloadSize)
    assertTheStream(stream, atLeast: 100)
  }

  func testTheAdvancedProfileIsSpokenToo() async throws {
    let sender = try peer(profile: RIST_PROFILE_ADVANCED)
    let source = try source(
      port: sender.port, configuration: .init(connectTimeout: 10, stallTimeout: 10, profile: .advanced, buffer: 100))
    sender.send()
    let stream = try await read(source, atLeast: 100 * RISTTestPeer.payloadSize)
    assertTheStream(stream, atLeast: 100)
  }

  func testTheOptionsTheLibraryIsGivenAreTaken() async throws {
    let sender = try peer()
    let query = "?buffer=100&buffer-min=100&buffer-max=200&reorder-buffer=20&rtt-min=5&rtt-max=200&bandwidth=20000"
      + "&return-bandwidth=2000&congestion-control=1&timing-mode=0&min-retries=3&max-retries=10"
      + "&session-timeout=3000&keepalive-interval=500&cname=player&compression=0&key-rotation=100000"
    let source = try source(port: sender.port, query: query)
    sender.send()
    let stream = try await read(source, atLeast: 100 * RISTTestPeer.payloadSize)
    assertTheStream(stream, atLeast: 100)
  }

  // ── Loss ────────────────────────────────────────────

  func testWhatTheNetworkLosesIsAskedForAgainAndArrives() async throws {
    let sender = try peer()
    let relay = try UDPLossyRelay(target: sender.port, everyNth: 7)
    defer { relay.stop() }
    let source = try source(port: relay.port, configuration: .init(connectTimeout: 10, stallTimeout: 10, buffer: 400))
    sender.send(every: 0.006)
    let stream = try await read(source, atLeast: 300 * RISTTestPeer.payloadSize)
    let counts = relay.counts
    XCTAssertGreaterThan(counts.dropped, 10, "the network did lose payloads: \(counts)")
    assertTheStream(stream, atLeast: 300)
  }

  // ── Encryption that does not match ──────────────────

  /// RIST does not check a passphrase, so what a wrong one gives is not the stream:
  /// either nothing, or bytes that are not it.
  func testAWrongPassphraseDoesNotGiveTheStream() async throws {
    let sender = try peer(secret: "the sender's passphrase")
    let source = try source(
      port: sender.port, configuration: .init(connectTimeout: 3, stallTimeout: 3, buffer: 100, secret: "another passphrase"))
    sender.send()
    do {
      let stream = try await read(source, atLeast: 20 * RISTTestPeer.payloadSize)
      XCTAssertNil(RISTTestPeer.numbers(in: whole(stream, count: 20)), "a wrong passphrase gave the stream")
    } catch let error as UmbelError {
      guard case .sourceUnavailable = error else { return XCTFail("\(error)") }
    }
  }

  func testEncryptionOnOneSideOnlyGivesNothing() async throws {
    let cases: [(String, String?, String?)] = [
      ("a sender that encrypts, a receiver that cannot decrypt", "shared secret", nil),
      ("a sender that sends clear, a receiver that wants encryption", nil, "shared secret"),
    ]
    for (name, senderSecret, receiverSecret) in cases {
      let sender = try peer(secret: senderSecret)
      let source = try source(
        port: sender.port, configuration: .init(connectTimeout: 1.5, stallTimeout: 1.5, buffer: 100, secret: receiverSecret))
      sender.send()
      do {
        let stream = try await read(source, atLeast: 20 * RISTTestPeer.payloadSize)
        XCTAssertNil(RISTTestPeer.numbers(in: whole(stream, count: 20)), "\(name): the stream arrived")
      } catch let error as UmbelError {
        XCTAssertEqual(error, .sourceUnavailable(detail: "connection timed out"), name)
      }
      sender.stop()
    }
  }

  // ── Silence, cancelling, stopping ───────────────────

  func testASenderThatIsNotThereIsGivenUpOnAtTheConnectDeadline() async throws {
    let nobody = try RISTTestPeer()  // for a port; nothing is sent, and nothing answers
    nobody.stop()
    let source = try source(
      port: nobody.port, configuration: .init(connectTimeout: 0.8, stallTimeout: 10, buffer: 100))
    let began = Date()
    do {
      _ = try await source.readNext(maxLength: 1_000)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "connection timed out"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
  }

  func testASenderThatGoesQuietIsGivenUpOnAtTheStallDeadline() async throws {
    let sender = try peer()
    let source = try source(
      port: sender.port, configuration: .init(connectTimeout: 10, stallTimeout: 1, buffer: 100))
    sender.send()
    let first = try await read(source, atLeast: 10 * RISTTestPeer.payloadSize)
    XCTAssertFalse(first.isEmpty)
    sender.pause()
    let began = Date()
    do {
      // What was in flight comes first; then the silence.
      while true { _ = try await source.readNext(maxLength: 100_000) }
    } catch {
      XCTAssertEqual(error as? UmbelError, .sourceUnavailable(detail: "no data received"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 5)
  }

  func testACancelledReadGivesUpAtOnceAndStoppingEndsTheRest() async throws {
    let nobody = try RISTTestPeer()
    nobody.stop()
    let source = try source(
      port: nobody.port, configuration: .init(connectTimeout: 60, stallTimeout: 60, buffer: 100))
    let began = Date()
    let waiting = Task { try await source.readNext(maxLength: 1_000) }
    try await Task.sleep(nanoseconds: 300_000_000)
    waiting.cancel()
    do {
      _ = try await waiting.value
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
    XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    let stopped = Date()
    await source.invalidate()
    XCTAssertLessThan(Date().timeIntervalSince(stopped), 3, "stopping does not wait out the connect deadline")
    do {
      _ = try await source.readNext(maxLength: 1_000)
      XCTFail("a read went through")
    } catch {
      XCTAssertEqual(error as? UmbelError, .interrupted)
    }
  }
}
