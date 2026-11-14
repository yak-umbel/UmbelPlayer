import CoreMedia
import Foundation

/// A bounded queue of frames in presentation order.
///
/// Not only a buffer but **where frames are dropped**. Video has no queue
/// downstream the way audio does (the system holds scheduled audio for us),
/// and whenever the renderer is asked what to draw at time T it must already
/// have candidates at hand — so this layer has to exist, and the deciding is
/// its.
///
/// Small on purpose: a 4K frame is about 12 MB, three are 36 MB.
internal actor VideoFrameQueue {
  internal struct TakeResult: Sendable {
    internal let frame: VideoFrame?
    /// Late frames dropped before this take.
    internal let dropped: Int
  }

  private let capacity: Int
  private let tolerance: CMTime
  private var buffer: [VideoFrame] = []
  private var waitingProducers: [UInt64: CheckedContinuation<Void, Never>] = [:]
  private var nextWaiter: UInt64 = 0
  /// Up by one on each flush: a frame waiting for room across one belongs to
  /// before it — a seek, a stop — and does not go in after it.
  private var generation = 0
  /// Shown by the next take, apart from the queue; see `seed(_:)`.
  private var seeded: VideoFrame?
  private var droppedTotal = 0
  /// Whether any frame has been presented. With no frame before it, the head
  /// is drawn even if it lies in the future.
  private var hasPresented = false
  private var diagnostics: UmbelPlaybackDiagnostics?
  private var diagnosticOutput = "frames"
  private var lastTakeReason: String?
  private var lastTakeHead: CMTime?
  private var lastTakeDepth: Int?
  private var lastTakeHostTime = -Double.infinity

  internal init(capacity: Int = 3, tolerance: CMTime) {
    self.capacity = max(1, capacity)
    self.tolerance = tolerance
  }

  internal var depth: Int { buffer.count }
  internal var totalDropped: Int { droppedTotal }

  internal func setDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?, output: String) {
    self.diagnostics = diagnostics
    diagnosticOutput = output
    lastTakeReason = nil
    lastTakeHead = nil
    lastTakeDepth = nil
    lastTakeHostTime = -.infinity
  }

  /// Queues a frame, waiting while full: backpressure on decoding. Let go
  /// without it by a flush meanwhile, or by cancellation.
  internal func enqueue(_ frame: VideoFrame) async {
    let asOf = generation
    while buffer.count >= capacity {
      guard !Task.isCancelled else { return }
      nextWaiter &+= 1
      let waiter = nextWaiter
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          waitingProducers[waiter] = continuation
        }
      } onCancel: {
        Task { await self.release(waiter) }
      }
      guard generation == asOf else { return }
    }
    buffer.append(frame)
    diagnostics?.record("video_queued", values: [
      "framePTS": frame.presentationTime.seconds, "queueDepth": Double(buffer.count),
      "generation": Double(generation)], labels: ["output": diagnosticOutput])
  }

  /// The picture showing on another output, handed over when switching to
  /// this one: shown by the next take whatever its time, without waiting for
  /// room. Queued, it waited behind frames decoding had put there, which a
  /// paused clock would never take.
  internal func seed(_ frame: VideoFrame) {
    seeded = frame
  }

  /// Takes the frame to show at `time`.
  ///
  /// Late frames go first; then the head is taken if its time has come. A
  /// head still in the future gives nil, and the caller keeps showing the
  /// frame before.
  internal func take(at time: CMTime) -> TakeResult {
    if let frame = seeded {
      seeded = nil
      hasPresented = true
      return taken(frame, dropped: 0, reason: "seeded", at: time, head: buffer.first?.presentationTime)
    }
    var dropped = 0
    let stale = CMTimeSubtract(time, tolerance)

    // Drop every frame already late: drawing it now would be wrong.
    while buffer.count > 1, CMTimeCompare(buffer[0].presentationTime, stale) < 0 {
      buffer.removeFirst()
      dropped += 1
    }
    // The last frame left is late too: draw it anyway — better than nothing.
    if buffer.count == 1, CMTimeCompare(buffer[0].presentationTime, stale) < 0 {
      let frame = buffer.removeFirst()
      droppedTotal += dropped
      hasPresented = true
      resumeProducers()
      return taken(frame, dropped: dropped, reason: "lateLast", at: time, head: frame.presentationTime)
    }

    guard let head = buffer.first else {
      droppedTotal += dropped
      return taken(nil, dropped: dropped, reason: "empty", at: time, head: nil)
    }

    let deadline = CMTimeAdd(time, tolerance)
    if CMTimeCompare(head.presentationTime, deadline) > 0, hasPresented {
      // The head is still in the future and a frame is on screen: leave it
      // and keep showing that one.
      droppedTotal += dropped
      return taken(nil, dropped: dropped, reason: "future", at: time, head: head.presentationTime)
    }
    // The head is in the future and there is no frame to keep showing (new,
    // or just flushed): draw it now. A seek landing between two frames is
    // exactly this: the clock stands on the target, and the first frame after
    // it is up to a frame interval later; with a tolerance of half a frame,
    // its moment never comes, and while paused the picture would never
    // change. Such landings are common on real 24 fps content.

    let reason = hasPresented ? "due" : "first"
    buffer.removeFirst()
    droppedTotal += dropped
    hasPresented = true
    resumeProducers()
    return taken(head, dropped: dropped, reason: reason, at: time, head: head.presentationTime)
  }

  private func taken(
    _ frame: VideoFrame?, dropped: Int, reason: String, at time: CMTime, head: CMTime?
  ) -> TakeResult {
    if let diagnostics {
      let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
      // Unchanged empty/future observations need no line at every display tick.
      if frame != nil || dropped > 0 || reason != lastTakeReason
        || head != lastTakeHead || buffer.count != lastTakeDepth || host - lastTakeHostTime >= 1 {
        var values = ["clock": time.seconds, "queueDepth": Double(buffer.count),
                      "dropped": Double(dropped), "tolerance": tolerance.seconds,
                      "generation": Double(generation)]
        if let head {
          values["headPTS"] = head.seconds
          values["headMinusClock"] = (head - time).seconds
        }
        if let frame { values["framePTS"] = frame.presentationTime.seconds }
        diagnostics.record("video_take", values: values,
                           labels: ["reason": reason, "output": diagnosticOutput])
        lastTakeReason = reason
        lastTakeHead = head
        lastTakeDepth = buffer.count
        lastTakeHostTime = host
      }
    }
    return TakeResult(frame: frame, dropped: dropped)
  }

  /// Empties the queue after a seek, so frames from before do not show at
  /// the new position. The count of dropped frames is **not** reset: it is a
  /// diagnostic.
  internal func flush() {
    generation += 1
    seeded = nil
    buffer.removeAll()
    // Flushed, there is no frame before; the next is drawn however far off.
    hasPresented = false
    lastTakeReason = nil
    lastTakeHead = nil
    lastTakeDepth = nil
    lastTakeHostTime = -.infinity
    diagnostics?.record("video_flush", values: ["generation": Double(generation)],
                        labels: ["output": diagnosticOutput])
    resumeProducers()
  }

  private func resumeProducers() {
    let waiting = waitingProducers.values
    waitingProducers.removeAll()
    for producer in waiting { producer.resume() }
  }

  /// One waiter let go: its task was cancelled.
  private func release(_ waiter: UInt64) {
    waitingProducers.removeValue(forKey: waiter)?.resume()
  }
}
