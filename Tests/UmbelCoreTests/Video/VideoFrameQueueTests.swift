import CoreMedia
import XCTest
@testable import UmbelCore

private func frame(atSeconds seconds: Double) -> VideoFrame {
  let buffer = VideoFrame.makeTestPixelBuffer(
    width: 4, height: 4, luma: 128, cb: 128, cr: 128)!
  return VideoFrame(
    presentationTime: CMTime(seconds: seconds, preferredTimescale: 600),
    pixelBuffer: buffer,
    width: 4,
    height: 4,
    color: VideoColorDescription(matrix: .bt709, range: .limited)
  )
}

private func time(_ seconds: Double) -> CMTime {
  CMTime(seconds: seconds, preferredTimescale: 600)
}

final class VideoFrameQueueTests: XCTestCase {
  /// Tolerance of half a frame interval: 0.02 s at 25 frames a second.
  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  func testTakesFrameWhoseTimeHasArrived() async {
    let queue = VideoFrameQueue(capacity: 3, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0))
    let result = await queue.take(at: time(0))
    XCTAssertEqual(result.frame?.presentationTime.seconds, 0)
    XCTAssertEqual(result.dropped, 0)
  }

  func testReturnsNilWhenHeadIsStillInFuture() async {
    let queue = VideoFrameQueue(capacity: 3, tolerance: tolerance)
    // Present a frame first — "keep showing the last frame" needs a last one.
    await queue.enqueue(frame(atSeconds: 0.5))
    let first = await queue.take(at: time(0.5))
    XCTAssertNotNil(first.frame)

    await queue.enqueue(frame(atSeconds: 1.0))
    let result = await queue.take(at: time(0.5))
    XCTAssertNil(result.frame, "nothing is taken while the head is in the future — the last frame stays")
    XCTAssertEqual(result.dropped, 0)
    let depth = await queue.depth
    XCTAssertEqual(depth, 1, "a frame not taken stays in the queue")
  }

  /// With no frame to keep showing, the head is drawn even in the future.
  ///
  /// A seek landing between two frames is exactly this: the clock stands on
  /// the target, the first frame after it is up to a frame interval later,
  /// and the tolerance is half a frame. Not drawn, the picture would never
  /// change while paused. Such landings are common on real 24 fps content —
  /// a made-up fixture with the target on a frame boundary misses them.
  func testFutureHeadIsPresentedWhenNothingHasBeenShown() async {
    let queue = VideoFrameQueue(capacity: 3, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 1.0))
    let result = await queue.take(at: time(0.5))
    XCTAssertNotNil(result.frame, "with no picture yet, the head is drawn however far off")
  }

  /// Flushed, there is no last frame, so the next is presented
  /// unconditionally too.
  func testFlushRestoresTheUnconditionalFirstFrame() async {
    let queue = VideoFrameQueue(capacity: 3, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0.5))
    _ = await queue.take(at: time(0.5))
    await queue.flush()

    await queue.enqueue(frame(atSeconds: 9.0))
    let result = await queue.take(at: time(0.5))
    XCTAssertNotNil(result.frame, "after a flush there is no last frame to keep showing")
  }

  func testDropsStaleFramesAndTakesTheCurrentOne() async {
    let queue = VideoFrameQueue(capacity: 8, tolerance: tolerance)
    for index in 0..<5 {
      await queue.enqueue(frame(atSeconds: Double(index) * 0.04))
    }
    // The clock is at 0.16 s: the first four frames are late.
    let result = await queue.take(at: time(0.16))
    XCTAssertEqual(result.frame?.presentationTime.seconds ?? -1, 0.16, accuracy: 0.001)
    XCTAssertEqual(result.dropped, 4, "late frames are dropped and counted")
  }

  func testDroppedCountAccumulates() async {
    let queue = VideoFrameQueue(capacity: 8, tolerance: tolerance)
    for index in 0..<5 {
      await queue.enqueue(frame(atSeconds: Double(index) * 0.04))
    }
    _ = await queue.take(at: time(0.16))
    let total = await queue.totalDropped
    XCTAssertEqual(total, 4)
  }

  func testFrameWithinToleranceIsTaken() async {
    let queue = VideoFrameQueue(capacity: 3, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0.51))
    // 0.51 is later than 0.50, but within half a frame interval: taken.
    let result = await queue.take(at: time(0.50))
    XCTAssertNotNil(result.frame, "a frame within tolerance is taken, or every frame would be a beat late")
  }

  func testEmptyQueueReturnsNilWithoutDropping() async {
    let queue = VideoFrameQueue(capacity: 3, tolerance: tolerance)
    let result = await queue.take(at: time(1))
    XCTAssertNil(result.frame)
    XCTAssertEqual(result.dropped, 0)
  }

  func testEnqueueBlocksWhenFull() async {
    let queue = VideoFrameQueue(capacity: 2, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0))
    await queue.enqueue(frame(atSeconds: 0.04))
    let depth = await queue.depth
    XCTAssertEqual(depth, 2)

    // The third frame gets in only once one is taken — the backpressure.
    let producer = Task { await queue.enqueue(frame(atSeconds: 0.08)) }
    _ = await queue.take(at: time(0))
    await producer.value
    let after = await queue.depth
    XCTAssertEqual(after, 2)
  }

  func testFlushEmptiesQueueAndUnblocksProducers() async {
    let queue = VideoFrameQueue(capacity: 1, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0))
    let producer = Task { await queue.enqueue(frame(atSeconds: 0.04)) }
    await queue.flush()
    await producer.value
    let depth = await queue.depth
    XCTAssertLessThanOrEqual(depth, 1, "no old frame left after flush, and the waiter let go")
  }

  /// A frame waiting for room across a flush belongs to before it — a seek,
  /// a stop — and does not go in after it.
  func testAFrameWaitingAcrossAFlushIsDropped() async {
    let queue = VideoFrameQueue(capacity: 1, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0))
    let producer = Task { await queue.enqueue(frame(atSeconds: 0.04)) }
    try? await Task.sleep(nanoseconds: 50_000_000)
    await queue.flush()
    await producer.value
    let depth = await queue.depth
    XCTAssertEqual(depth, 0)
  }

  /// Cancelled while waiting for room, it lets go, the frame left out.
  func testACancelledWaitLetsGo() async {
    let queue = VideoFrameQueue(capacity: 1, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0))
    let producer = Task { await queue.enqueue(frame(atSeconds: 0.04)) }
    try? await Task.sleep(nanoseconds: 50_000_000)
    producer.cancel()
    let finished = await withTaskGroup(of: Bool.self) { group in
      group.addTask { await producer.value; return true }
      group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return false }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    XCTAssertTrue(finished)
    let depth = await queue.depth
    XCTAssertEqual(depth, 1, "only the frame that was there")
    if !finished { await queue.flush() }
  }

  /// A picture handed over from another output goes in whatever the room,
  /// and is shown next, whatever its time: paused, the clock stands on it.
  func testASeededFrameIsShownNextWithoutWaiting() async {
    let queue = VideoFrameQueue(capacity: 2, tolerance: tolerance)
    await queue.enqueue(frame(atSeconds: 0.04))
    _ = await queue.take(at: time(0.04))
    await queue.enqueue(frame(atSeconds: 0.08))
    await queue.enqueue(frame(atSeconds: 0.12))
    await queue.seed(frame(atSeconds: 0.04))
    let shown = await queue.take(at: time(0.04))
    XCTAssertEqual(shown.frame?.presentationTime.seconds ?? -1, 0.04, accuracy: 1e-6)
    let depth = await queue.depth
    XCTAssertEqual(depth, 2, "the queued frames stay, for when the clock gets to them")
  }

  func testAFlushForgetsTheSeed() async {
    let queue = VideoFrameQueue(capacity: 2, tolerance: tolerance)
    await queue.seed(frame(atSeconds: 0.04))
    await queue.flush()
    let shown = await queue.take(at: time(0.04))
    XCTAssertNil(shown.frame)
  }

  func testFlushDoesNotResetTotalDropped() async {
    let queue = VideoFrameQueue(capacity: 8, tolerance: tolerance)
    for index in 0..<3 {
      await queue.enqueue(frame(atSeconds: Double(index) * 0.04))
    }
    _ = await queue.take(at: time(0.08))
    await queue.flush()
    let total = await queue.totalDropped
    XCTAssertEqual(total, 2, "the running count of drops is a diagnostic, not reset by flush")
  }
}
