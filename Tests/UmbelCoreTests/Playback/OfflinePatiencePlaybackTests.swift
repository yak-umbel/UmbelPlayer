import CoreMedia
import XCTest
@testable import UmbelCore

private final class StillHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

private final class ManualHostTime: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock()
    defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock()
    defer { lock.unlock() }
    seconds += delta
  }
}

/// Answers byte-range requests for a fixture, except while the device is
/// offline: then every request fails as the system fails it, at once.
private final class OutageFileStub: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var content = Data()
  nonisolated(unsafe) private static var isOffline = false
  nonisolated(unsafe) private static var refused = 0
  nonisolated(unsafe) private static var lastRefusal: TimeInterval?

  static func serve(_ data: Data) {
    lock.lock()
    (content, isOffline, refused, lastRefusal) = (data, false, 0, nil)
    lock.unlock()
  }

  static func setOffline(_ offline: Bool) {
    lock.lock()
    isOffline = offline
    lock.unlock()
  }

  static var refusedRequests: Int {
    lock.lock()
    defer { lock.unlock() }
    return refused
  }

  /// When the last request was refused, on the system's uptime clock.
  static var lastRefusalTime: TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return lastRefusal
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.lock.lock()
    let content = Self.content
    let offline = Self.isOffline
    if offline {
      Self.refused += 1
      Self.lastRefusal = ProcessInfo.processInfo.systemUptime
    }
    Self.lock.unlock()
    if offline {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let spec = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-").dropFirst("bytes=".count)
    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
    let start = Int(parts.first ?? "") ?? 0
    guard start < content.count else {
      let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Range": "bytes */\(content.count)", "Content-Length": "0"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    let end = min(Int(parts.count > 1 ? parts[1] : "") ?? content.count - 1, content.count - 1)
    let body = content.subdata(in: start..<(end + 1))
    let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
      "Content-Range": "bytes \(start)-\(end)/\(content.count)", "Content-Length": "\(body.count)",
      "Accept-Ranges": "bytes"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// The device loses its network for a few seconds — Wi-Fi dropped, a dead
/// spot — and gets it back: playback over the network goes on from where it
/// was, rather than failing for want of retries that ran out in moments.
final class OfflinePatiencePlaybackTests: XCTestCase {
  private func waitUntil(_ what: String, within seconds: Double = 10, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting until \(what)")
  }

  /// A session over the network fixture, ranges short so that reading on
  /// needs a request now and then.
  private func network(
    hostTime: any HostTimeSource, audio: VirtualAudioOutput, buffering: BufferingConfiguration = .init(),
    retryPolicy: UmbelHTTPSource.RetryPolicy = .init()
  ) async throws -> PlaybackSession {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent("seek_grid.mp4")
    OutageFileStub.serve(try Data(contentsOf: fixture))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OutageFileStub.self]
    let source = UmbelHTTPSource(
      url: URL(string: "http://stub.invalid/seek_grid.mp4")!, session: URLSession(configuration: configuration),
      retryPolicy: retryPolicy, maximumRangeLength: 8_192)
    let session = PlaybackSession(
      source: source, audioOutput: audio, hostTime: hostTime,
      configuration: DemuxConfiguration(ioBufferSize: 2_048), buffering: buffering)
    addTeardownBlock {
      OutageFileStub.setOffline(false)
      await session.stop()
    }
    try await session.load()
    return session
  }

  func testAnOutageOfAFewSecondsIsWaitedOutByDefault() async throws {
    let session = try await network(
      hostTime: StillHostTime(), audio: VirtualAudioOutput(hostTime: StillHostTime()))

    OutageFileStub.setOffline(true)
    try await session.play()
    await waitUntil("a request is refused") { OutageFileStub.refusedRequests > 0 }
    // Past what the default retries would have spent: about two seconds.
    try await Task.sleep(nanoseconds: 3_500_000_000)
    let during = await session.bufferedDuration.seconds

    OutageFileStub.setOffline(false)
    await waitUntil("reading goes on") { await session.bufferedDuration.seconds > during + 1 }
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed)
  }

  /// What is buffered plays; when it has run out the session is buffering —
  /// not failed — and plays on once the network is back.
  func testTheSessionBuffersWhileOfflineAndPlaysOnAfter() async throws {
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.2)
    // Reading ahead only a few seconds, so playing on needs requests.
    let session = try await network(
      hostTime: host, audio: output, buffering: BufferingConfiguration(startThreshold: 2, lowWatermark: 1, target: 3))

    func step() async {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }

    try await session.play()
    await waitUntil("it plays") {
      await step()
      return await session.phase == .playing
    }
    OutageFileStub.setOffline(true)
    await waitUntil("the session is buffering for want of data") {
      await step()
      return await session.phase == .buffering
    }
    await waitUntil("a request is refused") { OutageFileStub.refusedRequests > 0 }
    // Past what the default retries would have spent: about two seconds.
    try await Task.sleep(nanoseconds: 3_500_000_000)
    let during = await session.phase
    XCTAssertEqual(during, .buffering, "the retries are gone, and it still waits")

    OutageFileStub.setOffline(false)
    await waitUntil("it plays on") {
      await step()
      return await session.phase == .playing
    }
  }

  /// An outage that outlasts the patience ends in failure, once the patience
  /// has run out and not much after.
  func testAnOutagePastThePatienceFailsWhenItRunsOut() async throws {
    let host = ManualHostTime()
    let output = VirtualAudioOutput(hostTime: host, maxPendingSeconds: 0.2)
    let session = try await network(
      hostTime: host, audio: output, buffering: BufferingConfiguration(startThreshold: 2, lowWatermark: 1, target: 3),
      retryPolicy: .init(maxRetries: 3, initialDelay: 0.25, jitter: 0, offlinePatience: 2))

    func step() async {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }

    try await session.play()
    await waitUntil("it plays") {
      await step()
      return await session.phase == .playing
    }
    OutageFileStub.setOffline(true)
    let began = Date()
    let beganUptime = ProcessInfo.processInfo.systemUptime
    var turns = 0
    var bufferedAtTwo: Double?
    await waitUntil("it fails", within: 15) {
      turns += 1
      await step()
      if bufferedAtTwo == nil, Date().timeIntervalSince(began) >= 2 {
        bufferedAtTwo = await session.bufferedDuration.seconds
      }
      return await session.phase == .failed
    }
    let elapsed = Date().timeIntervalSince(began)
    // Shown only if a check below fails. The source gives up when the patience
    // has run out; the session reports it once what it still held has played
    // out, in real time, so this can run well past the patience on a slow machine.
    let gaveUp = OutageFileStub.lastRefusalTime.map { $0 - beganUptime }
    let seen = String(
      format: "failed after %.2f s in %d turns of %.0f ms; the source's last refused request at %.2f s; "
        + "still buffered at 2 s: %.2f s",
      elapsed, turns, elapsed * 1000 / Double(max(1, turns)), gaveUp ?? -1, bufferedAtTwo ?? -1)
    XCTAssertGreaterThanOrEqual(elapsed, 2, "not before the patience has run out; " + seen)
    XCTAssertLessThan(elapsed, 3.5, "and not long after; " + seen)
  }
}
