import CoreMedia
import XCTest
@testable import UmbelCore

private final class StillHostTime: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

/// Which segment holds its reads, as a connection gone quiet does, and what
/// became of the reads held.
private final class StallGate: @unchecked Sendable {
  private let lock = NSLock()
  private var name: String?
  private var held = 0
  private var cancelled = 0

  func stall(_ name: String?) { lock.withLock { self.name = name } }
  func isStalling(_ segment: String) -> Bool { lock.withLock { name == segment } }
  func holdBegan() { lock.withLock { held += 1 } }
  func holdCancelled() { lock.withLock { cancelled += 1 } }
  var snapshot: (held: Int, cancelled: Int) { lock.withLock { (held, cancelled) } }
}

/// A segment that holds its reads while the gate says so, and lets go of one
/// when the task reading is cancelled or the source is invalidated.
private actor StallingSegment: UmbelRandomAccessSource {
  private let inner: any UmbelRandomAccessSource
  private let name: String
  private let gate: StallGate
  private var isInvalidated = false

  init(url: URL, server: FixtureServer, gate: StallGate) {
    inner = server.source(url)
    name = url.lastPathComponent
    self.gate = gate
  }

  var contentLength: Int64? { get async { await inner.contentLength } }

  func read(offset: Int64, maxLength: Int) async throws -> Data {
    if gate.isStalling(name) {
      gate.holdBegan()
      while gate.isStalling(name), !isInvalidated {
        do {
          try await Task.sleep(nanoseconds: 10_000_000)
        } catch {
          gate.holdCancelled()
          throw UmbelError.interrupted
        }
      }
    }
    guard !isInvalidated else { throw UmbelError.interrupted }
    return try await inner.read(offset: offset, maxLength: maxLength)
  }

  func invalidate() { isInvalidated = true }
}

/// The playlist, which opens its segments through the gate.
private actor StallingPlaylist: UmbelLocatedSource {
  private let inner: FixtureLocatedSource
  private let server: FixtureServer
  private let gate: StallGate

  init(url: URL, server: FixtureServer, gate: StallGate) {
    inner = server.source(url)
    self.server = server
    self.gate = gate
  }

  var location: URL { get async { await inner.location } }
  var contentLength: Int64? { get async { await inner.contentLength } }
  func read(offset: Int64, maxLength: Int) async throws -> Data {
    try await inner.read(offset: offset, maxLength: maxLength)
  }
  func invalidate() async { await inner.invalidate() }

  func source(for url: URL) async -> any UmbelRandomAccessSource {
    StallingSegment(url: url, server: server, gate: gate)
  }
}

private actor Flag {
  private(set) var isSet = false
  func set() { isSet = true }
}

/// Reading a playlist is given up as reading a file is: a seek to somewhere
/// not read yet does not wait for a segment that will not come.
final class PlaylistReadInterruptTests: XCTestCase {
  private func playlistURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/hls").appendingPathComponent(path)
  }

  private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<250 {
      if await condition() { return }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("timed out waiting until \(what)")
  }

  /// Plays `playlist`, which opens by `path` (see `demux_open`), until a read
  /// of the segment `held` is held, then seeks to `seconds`, which is read
  /// from nothing already read.
  private func seekPastAStalledSegment(
    playlist: String, path: String, held: String, to seconds: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let gate = StallGate()
    let source = StallingPlaylist(url: playlistURL(playlist), server: FixtureServer(), gate: gate)
    let diagnostics = UmbelPlaybackDiagnostics()
    let session = PlaybackSession(
      source: source, audioOutput: VirtualAudioOutput(hostTime: StillHostTime()),
      hostTime: StillHostTime(), diagnostics: diagnostics)
    addTeardownBlock {
      gate.stall(nil)
      await session.stop()
    }
    try await session.load()
    let opened = diagnostics.snapshot().events.first { $0.name == "demux_open" }?.labels["path"]
    XCTAssertEqual(opened, path, "the playlist is read the way this test is about", file: file, line: line)
    gate.stall(held)
    try await session.play()
    await waitUntil("a segment read is held") { gate.snapshot.held > 0 }

    let done = Flag()
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    let seeking = Task {
      try await session.seek(to: target)
      await done.set()
    }
    var waited = 0.0
    while waited < 3, !(await done.isSet) {
      try await Task.sleep(nanoseconds: 20_000_000)
      waited += 0.02
    }
    let finishedInTime = await done.isSet
    // Let go either way, so a seek that waits ends and the test does not hang.
    gate.stall(nil)
    try await seeking.value

    XCTAssertTrue(finishedInTime, "the seek waited for the stalled segment", file: file, line: line)
    XCTAssertGreaterThan(gate.snapshot.cancelled, 0, "the held read was asked to stop", file: file, line: line)
    let phase = await session.phase
    XCTAssertNotEqual(phase, .failed, file: file, line: line)
    let lost = diagnostics.snapshot().events.filter { $0.name == "hls_segment_lost" }
    XCTAssertTrue(lost.isEmpty, "a read given up is no segment lost", file: file, line: line)
  }

  /// Seconds 2 to 4 are in `main1`, which holds; the target, 12.5 s, is in
  /// a run read from nothing already read.
  func testASeekOutsideTheBufferDoesNotWaitForAStalledSegment() async throws {
    try await seekPastAStalledSegment(playlist: "ad.m3u8", path: "playlist", held: "main1", to: 12.5)
  }

  /// The same where FFmpeg's own reading plays the playlist, as for a
  /// playlist of sound alone: seconds 2 to 4 are in `a1.aac`, which holds.
  func testTheSameWhereFFmpegReadsThePlaylist() async throws {
    try await seekPastAStalledSegment(
      playlist: "packed/index.m3u8", path: "hlsFallback", held: "a1.aac", to: 5.5)
  }
}
