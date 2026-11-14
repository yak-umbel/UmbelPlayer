import CoreMedia
import Foundation
import XCTest
@testable import UmbelCore

/// Blocking native work is substituted at the ownership boundary; the real
/// queue, admission, cancellation and result delivery remain under test.
final class AsyncVideoDecodeSessionTests: XCTestCase {
  func testFirstSubmissionReturnsWhileNativeCallIsBlockedAndNextCanOverlapConsumption() async throws {
    let engine = GatedVideoEngine(blocked: [1, 2])
    defer { engine.releaseAll() }
    let session = AsyncVideoDecodeSession(engine: engine)
    let first = try await session.decode(Self.packet(1))
    XCTAssertTrue(first.isEmpty)
    await fulfillment(of: [engine.started(1)], timeout: 2)
    let second = Task { [session, packet = Self.packet(2)] in try await session.decode(packet) }
    engine.release(1)
    let frames = try await second.value
    XCTAssertEqual(frames.map(\.presentationTime.seconds), [1])
    await fulfillment(of: [engine.started(2)], timeout: 2)
    // Packet 2 is still decoding while packet 1's result is owned by us.
    engine.release(2)
    let tail = try await session.drain()
    XCTAssertEqual(tail.map(\.presentationTime.seconds), [2, 99])
    let again = try await session.drain()
    XCTAssertTrue(again.isEmpty)
    await session.close()
  }

  func testConcurrentConsumerCannotAdmitThirdPacket() async throws {
    let engine = GatedVideoEngine(blocked: [1])
    defer { engine.releaseAll() }
    let session = AsyncVideoDecodeSession(engine: engine)
    _ = try await session.decode(Self.packet(1))
    await fulfillment(of: [engine.started(1)], timeout: 2)
    let second = Task { [session, packet = Self.packet(2)] in try await session.decode(packet) }
    // Actor observation happens after the second call has acquired ownership.
    try await waitForConsumer(session)
    do {
      _ = try await session.decode(Self.packet(3))
      XCTFail("the third packet must not be admitted")
    } catch AsyncVideoDecodeError.busy {}
    engine.release(1)
    let frames = try await second.value
    let tail = try await session.drain()
    XCTAssertEqual((frames + tail).map(\.presentationTime.seconds), [1, 2, 99])
    XCTAssertEqual(engine.decoded, [1, 2])
    await session.close()
  }

  func testCancellationReleasesConsumerAndPreventsQueuedPacket() async throws {
    let engine = GatedVideoEngine(blocked: [1])
    defer { engine.releaseAll() }
    let session = AsyncVideoDecodeSession(engine: engine)
    _ = try await session.decode(Self.packet(1))
    await fulfillment(of: [engine.started(1)], timeout: 2)
    let second = Task { [session, packet = Self.packet(2)] in try await session.decode(packet) }
    try await waitForConsumer(session)
    second.cancel()
    do { _ = try await second.value; XCTFail("cancelled consumer returned frames") }
    catch is CancellationError {}
    engine.release(1)
    await session.flush()
    XCTAssertEqual(engine.decoded, [1])
    let first = try await session.decode(Self.packet(3))
    XCTAssertTrue(first.isEmpty)
    let frames = try await session.drain()
    XCTAssertEqual(frames.map(\.presentationTime.seconds), [3, 99])
    await session.close()
  }

  func testFlushRejectsOldResultsAndWaitsForNativeCleanup() async throws {
    let engine = GatedVideoEngine(blocked: [1])
    defer { engine.releaseAll() }
    let session = AsyncVideoDecodeSession(engine: engine)
    _ = try await session.decode(Self.packet(1))
    await fulfillment(of: [engine.started(1)], timeout: 2)
    let second = Task { [session, packet = Self.packet(2)] in try await session.decode(packet) }
    try await waitForConsumer(session)
    let flush = Task { await session.flush() }
    do { _ = try await second.value; XCTFail("stale result escaped flush") }
    catch is CancellationError {}
    XCTAssertEqual(engine.events, ["decode1"])
    engine.release(1)
    await flush.value
    XCTAssertEqual(engine.events, ["decode1", "flush"])
    _ = try await session.decode(Self.packet(3))
    let fresh = try await session.drain()
    XCTAssertEqual(fresh.map(\.presentationTime.seconds), [3, 99])
    await session.close()
  }

  func testCloseCancelsConsumerBeforeClosingNativeContext() async throws {
    let engine = GatedVideoEngine(blocked: [1])
    defer { engine.releaseAll() }
    let session = AsyncVideoDecodeSession(engine: engine)
    _ = try await session.decode(Self.packet(1))
    await fulfillment(of: [engine.started(1)], timeout: 2)
    let second = Task { [session, packet = Self.packet(2)] in try await session.decode(packet) }
    try await waitForConsumer(session)
    let close = Task { await session.close() }
    do { _ = try await second.value; XCTFail("stale result escaped close") }
    catch is CancellationError {}
    XCTAssertEqual(engine.events, ["decode1"])
    engine.release(1)
    await close.value
    XCTAssertEqual(engine.events, ["decode1", "close"])
    let frames = try await session.decode(Self.packet(3))
    XCTAssertTrue(frames.isEmpty)
  }

  func testNativeFailureIsDeliveredToConsumer() async throws {
    let engine = GatedVideoEngine(blocked: [1], failing: 1)
    defer { engine.releaseAll() }
    let session = AsyncVideoDecodeSession(engine: engine)
    _ = try await session.decode(Self.packet(1))
    await fulfillment(of: [engine.started(1)], timeout: 2)
    let second = Task { [session, packet = Self.packet(2)] in try await session.decode(packet) }
    try await waitForConsumer(session)
    engine.release(1)
    do { _ = try await second.value; XCTFail("native failure disappeared") }
    catch GatedVideoEngine.Failure.packet {}
    await session.close()
  }

  func testDrainFailureIsReportedOnce() async throws {
    let engine = GatedVideoEngine(blocked: [], failingDrain: true)
    let session = AsyncVideoDecodeSession(engine: engine)
    do { _ = try await session.drain(); XCTFail("drain failure disappeared") }
    catch GatedVideoEngine.Failure.packet {}
    let again = try await session.drain()
    XCTAssertTrue(again.isEmpty)
    XCTAssertEqual(engine.events, ["drain"])
    await session.close()
  }

  private func waitForConsumer(_ session: AsyncVideoDecodeSession) async throws {
    let deadline = Date().addingTimeInterval(2)
    while await !session.isConsuming {
      if Date() >= deadline { throw GatedVideoEngine.Failure.consumerTimeout }
      await Task.yield()
    }
  }

  private static func packet(_ id: Int) -> DemuxPacket {
    DemuxPacket(trackID: .init(rawValue: 0), data: Data([UInt8(id)]),
                presentationTime: CMTime(value: Int64(id), timescale: 1),
                decodeTime: .invalid, duration: .invalid, isKeyframe: true)
  }
}

private final class GatedVideoEngine: VideoDecodingEngine, @unchecked Sendable {
  enum Failure: Error { case packet, consumerTimeout }
  private let lock = NSLock()
  private var history: [String] = []
  private let gates: [Int: DispatchSemaphore]
  private let starts: [Int: XCTestExpectation]
  private let failing: Int?
  private let failingDrain: Bool

  init(blocked: [Int], failing: Int? = nil, failingDrain: Bool = false) {
    gates = Dictionary(uniqueKeysWithValues: blocked.map { ($0, DispatchSemaphore(value: 0)) })
    starts = Dictionary(uniqueKeysWithValues: blocked.map { ($0, XCTestExpectation(description: "decode \($0) started")) })
    self.failing = failing
    self.failingDrain = failingDrain
  }
  var events: [String] { lock.withLock { history } }
  var decoded: [Int] { events.compactMap { $0.hasPrefix("decode") ? Int($0.dropFirst(6)) : nil } }
  func started(_ id: Int) -> XCTestExpectation { starts[id]! }
  func release(_ id: Int) { gates[id]?.signal() }
  func releaseAll() { gates.values.forEach { $0.signal() } }
  func decode(_ packet: DemuxPacket, hidden: Bool) throws -> [VideoFrame] {
    let id = Int(packet.data[0])
    record("decode\(id)")
    starts[id]?.fulfill()
    if let gate = gates[id] {
      guard gate.wait(timeout: .now() + 10) == .success else { throw Failure.packet }
    }
    if failing == id { throw Failure.packet }
    return [frame(id)]
  }
  func drain() throws -> [VideoFrame] {
    record("drain")
    if failingDrain { throw Failure.packet }
    return [frame(99)]
  }
  func flush() { record("flush") }
  func renew() throws { record("renew") }
  func close() { record("close") }
  func setSkipsNonReference(_ skips: Bool) {}
  private func record(_ event: String) { lock.withLock { history.append(event) } }
  private func frame(_ id: Int) -> VideoFrame {
    VideoFrame(presentationTime: CMTime(value: Int64(id), timescale: 1),
               pixelBuffer: VideoFrame.makeTestPixelBuffer(width: 2, height: 2, luma: 16, cb: 128, cr: 128)!,
               width: 2, height: 2, color: VideoColorDescription(matrix: .bt709, range: .limited))
  }
}
