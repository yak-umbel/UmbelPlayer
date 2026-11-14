import CoreGraphics
import CoreMedia
import Darwin
import XCTest
@testable import UmbelCore

private final class ManualHost: HostTimeSource, @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: Double = 0

  var now: CMTime {
    lock.lock(); defer { lock.unlock() }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000)
  }

  func advance(seconds delta: Double) {
    lock.lock(); defer { lock.unlock() }
    seconds += delta
  }
}

/// Takes every picture and counts them.
private actor CountingRenderer: VideoRenderer {
  private let queue = VideoFrameQueue(capacity: 8, tolerance: CMTime(value: 1, timescale: 50))
  private(set) var received = 0

  func prepare(
    width: Int, height: Int, pixelAspectRatio: Double, color: VideoColorDescription
  ) async throws {}

  func enqueue(_ frame: VideoFrame) async throws {
    received += 1
    await queue.enqueue(frame)
  }

  func presentFrame(at time: CMTime) async throws -> PresentedFrame? {
    let result = await queue.take(at: time)
    return result.frame.map { PresentedFrame(presentationTime: $0.presentationTime, droppedFrames: result.dropped) }
  }

  func flush() async { await queue.flush() }
  var queueDepth: Int { get async { await queue.depth } }
  var totalDroppedFrames: Int { get async { await queue.totalDropped } }
  var subtitleCanvasSize: CGSize { .zero }
  func setSubtitles(_ bitmaps: [UmbelSubtitleBitmap]) async {}
  func setPictureGeometry(aspectRatio: Double?, scaling: UmbelPictureScaling) async {}
}

/// A session over a live stream off the network, end to end: loaded, playing,
/// pictures and sound delivered, not seekable, and let go on stopping.
///
/// The audio output is the bounded one a real device is: with one that takes
/// everything at once, the cache is emptied as fast as it fills and never
/// holds the start threshold, which only a stream's end gets past.
final class LiveNetworkPlaybackTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func waitUntil(
    _ description: String, file: StaticString = #filePath, line: UInt = #line,
    _ condition: () async -> Bool
  ) async throws -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
    return false
  }

  private func advance(
    _ session: PlaybackSession, _ host: ManualHost, _ output: VirtualAudioOutput, by seconds: Double
  ) async {
    for _ in 0..<Int(seconds / 0.1) {
      host.advance(seconds: 0.1)
      await output.advance(bySeconds: 0.1)
      await session.refreshClock()
    }
  }

  func testASessionPlaysATransportStreamOffTheNetwork() async throws {
    let payload = try Data(contentsOf: fixture("live_stream.ts"))
    let closed = DispatchSemaphore(value: 0)
    // The stream is not over: the peer sends what it has and goes quiet.
    let server = try LoopbackTCPServer { connection in
      connection.send(payload)
      _ = connection.waitForPeerClose(timeout: 10)
      closed.signal()
    }
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host)
    let renderer = CountingRenderer()
    let source = try UmbelNetworkStreamSource(
      url: URL(string: "tcp://127.0.0.1:\(server.port)")!, configuration: .init(connectTimeout: 3, stallTimeout: 10))
    let session = PlaybackSession(source: source, audioOutput: output, videoRenderer: renderer, hostTime: host)
    try await session.load()
    let seekable = await session.isSeekable
    XCTAssertFalse(seekable)
    let duration = await session.duration
    XCTAssertFalse(duration.isNumeric, "a stream read in order has no length to show")
    try await session.play()
    guard try await waitUntil("pictures and sound", {
      let pictures = await renderer.received
      let sound = await output.pendingSeconds
      return pictures >= 5 && sound > 0
    }) else { return }
    guard try await waitUntil("playing", { await session.phase == .playing }) else { return }
    await advance(session, host, output, by: 1)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 1, accuracy: 0.5, "time counts from where the stream was joined")
    let reason = await session.failureReason
    XCTAssertNil(reason)

    // The host made the source and owns it, as with any source: stopping the
    // session does not close it, invalidating does.
    await session.stop()
    await source.invalidate()
    XCTAssertEqual(closed.wait(timeout: .now() + 3), .success, "invalidating lets the connection go")
  }

  /// A connection that is cut mid-stream fails the session, with the source's
  /// own kind of error: not buffering for good, and not a stop that nobody
  /// asked for.
  func testACutConnectionFailsTheSessionWithASourceError() async throws {
    let payload = try Data(contentsOf: fixture("live_stream.ts"))
    let server = try LoopbackTCPServer { connection in
      connection.send(payload)
      usleep(300_000)
      connection.reset()
    }
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host)
    let renderer = CountingRenderer()
    let source = try UmbelNetworkStreamSource(
      url: URL(string: "tcp://127.0.0.1:\(server.port)")!, configuration: .init(connectTimeout: 3, stallTimeout: 10))
    let session = PlaybackSession(source: source, audioOutput: output, videoRenderer: renderer, hostTime: host)
    addTeardownBlock { await session.stop(); await source.invalidate() }
    try await session.load()
    try await session.play()
    // Played on, in step with the clock and with pictures taken as a display
    // would, until what had arrived runs out and the cut is what is left.
    var phase = await session.phase
    for _ in 0..<150 where phase != .failed {
      await advance(session, host, output, by: 0.1)
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 20_000_000)
      phase = await session.phase
    }
    XCTAssertEqual(phase, .failed, "a cut stream does not leave the session buffering")
    let reason = await session.failureReason
    guard case .sourceUnavailable? = reason else { return XCTFail("failed with \(String(describing: reason))") }
  }

  /// RTSP: a server that describes a stream and sends it, as a camera does,
  /// played through the session, and let go on invalidating.
  func testASessionPlaysRTSPOffTheNetwork() async throws {
    let payload = try Data(contentsOf: fixture("live_stream.ts"))
    let ended = DispatchSemaphore(value: 0)
    let server = try LoopbackRTSP.serve(
      sdp: LoopbackRTSP.sdp(media: "m=video 0 RTP/AVP 33"), packets: LoopbackRTSP.transportStream(payload),
      onEnd: { ended.signal() })
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host)
    let renderer = CountingRenderer()
    let source = try UmbelRTPStreamSource(
      url: URL(string: "rtsp://127.0.0.1:\(server.port)/stream")!, configuration: .init(connectTimeout: 4, stallTimeout: 10))
    let session = PlaybackSession(source: source, audioOutput: output, videoRenderer: renderer, hostTime: host)
    try await session.load()
    let seekable = await session.isSeekable
    XCTAssertFalse(seekable)
    let duration = await session.duration
    XCTAssertFalse(duration.isNumeric, "a stream read in order has no length to show")
    try await session.play()
    guard try await waitUntil("pictures and sound", {
      let pictures = await renderer.received
      let sound = await output.pendingSeconds
      return pictures >= 5 && sound > 0
    }) else { return }
    guard try await waitUntil("playing", { await session.phase == .playing }) else { return }
    await advance(session, host, output, by: 1)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 1, accuracy: 0.5, "time counts from where the stream was joined")
    let reason = await session.failureReason
    XCTAssertNil(reason)

    await session.stop()
    await source.invalidate()
    XCTAssertEqual(ended.wait(timeout: .now() + 3), .success, "invalidating lets the connection go")
  }

  /// A connection that is cut mid-stream fails the session with the source's
  /// own kind of error, over RTSP as over a plain socket.
  func testACutRTSPConnectionFailsTheSessionWithASourceError() async throws {
    let payload = try Data(contentsOf: fixture("live_stream.ts"))
    let server = try LoopbackRTSP.serve(
      sdp: LoopbackRTSP.sdp(media: "m=video 0 RTP/AVP 33"), packets: LoopbackRTSP.transportStream(payload),
      cutAfterPlay: true)
    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host)
    let renderer = CountingRenderer()
    let source = try UmbelRTPStreamSource(
      url: URL(string: "rtsp://127.0.0.1:\(server.port)/stream")!, configuration: .init(connectTimeout: 4, stallTimeout: 10))
    let session = PlaybackSession(source: source, audioOutput: output, videoRenderer: renderer, hostTime: host)
    addTeardownBlock { await session.stop(); await source.invalidate() }
    try await session.load()
    try await session.play()
    var phase = await session.phase
    for _ in 0..<200 where phase != .failed {
      await advance(session, host, output, by: 0.1)
      _ = try await session.renderVideoFrame()
      try await Task.sleep(nanoseconds: 20_000_000)
      phase = await session.phase
    }
    XCTAssertEqual(phase, .failed, "a cut stream does not leave the session buffering")
    let reason = await session.failureReason
    guard case .sourceUnavailable? = reason else { return XCTFail("failed with \(String(describing: reason))") }
  }

  /// Needs an `ffmpeg` to act as the server; without one it says so. Its
  /// timestamps start at an hour in, as a live stream's commonly do.
  func testASessionPlaysRTMPFromALocalServer() async throws {
    guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
      .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw XCTSkip("no ffmpeg to serve a stream")
    }
    let port = LoopbackTCPServer.unusedPort(type: SOCK_STREAM)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: ffmpeg)
    server.arguments = [
      "-hide_banner", "-loglevel", "quiet", "-re", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25",
      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-c:v", "flv", "-g", "25",
      "-c:a", "aac", "-output_ts_offset", "3600", "-t", "30", "-f", "flv",
      "-listen", "1", "rtmp://127.0.0.1:\(port)/live/test",
    ]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    addTeardownBlock { if server.isRunning { server.terminate() } }

    let host = ManualHost()
    let output = VirtualAudioOutput(hostTime: host)
    let renderer = CountingRenderer()
    var loaded: PlaybackSession?
    // The server takes one client and the source does not reconnect: try
    // again until the server is listening.
    for _ in 0..<40 where loaded == nil {
      let source = try UmbelNetworkStreamSource(
        url: URL(string: "rtmp://127.0.0.1:\(port)/live/test")!, configuration: .init(connectTimeout: 3, stallTimeout: 10))
      let attempt = PlaybackSession(source: source, audioOutput: output, videoRenderer: renderer, hostTime: host)
      do {
        try await attempt.load()
        loaded = attempt
      } catch {
        await attempt.stop()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    let session = try XCTUnwrap(loaded, "the server never came up")
    addTeardownBlock { await session.stop() }

    let tracks = await session.tracks
    XCTAssertTrue(tracks.contains { $0.kind == .video })
    XCTAssertTrue(tracks.contains { $0.kind == .audio })
    let seekable = await session.isSeekable
    XCTAssertFalse(seekable)
    try await session.play()
    guard try await waitUntil("pictures and sound", {
      let pictures = await renderer.received
      let sound = await output.pendingSeconds
      return pictures >= 5 && sound > 0
    }) else { return }
    guard try await waitUntil("playing", { await session.phase == .playing }) else { return }
    await advance(session, host, output, by: 1)
    let time = await session.currentTime
    XCTAssertEqual(time.seconds, 1, accuracy: 0.5, "time counts from where the stream was joined")
    let reason = await session.failureReason
    XCTAssertNil(reason)
  }
}
