import Foundation

/// Bytes of a live stream on their way from where they arrive to whoever
/// reads them: a bounded buffer, in order, with reads that wait.
///
/// A live stream cannot be read again, so nothing here is dropped but by
/// closing, and one read giving up (a cancelled task) must not end the
/// stream: `take` returns `.woken` and the reads that come next are served as
/// before. Above the high watermark the writer is told to hold back, and to
/// go on once reads have drained the buffer below the low one; a writer on a
/// thread of its own can instead wait in `waitForRoom()`.
///
/// A class with a condition rather than an actor: the writers are a URL
/// session's delegate calls and a blocking thread, both of which have to hand
/// bytes over synchronously.
final class LiveByteQueue: @unchecked Sendable {
  enum Outcome: Equatable, Sendable {
    /// The stream ended where it was meant to.
    case end
    case failure(UmbelError)
  }

  enum Taken: Equatable, Sendable {
    case data(Data)
    case end
    case failure(UmbelError)
    /// The read was cancelled with nothing to give; the stream is not over,
    /// and the reads that come next are served as before.
    case woken
  }

  static let defaultHighWatermark = 4 << 20
  static let defaultLowWatermark = 1 << 20

  private let condition = NSCondition()
  private let highWatermark: Int
  private let lowWatermark: Int
  private let hold: @Sendable () -> Void
  private let release: @Sendable () -> Void
  private var chunks: [Data] = []
  private var headOffset = 0
  private var buffered = 0
  private var outcome: Outcome?
  private var isClosed = false
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(
    highWatermark: Int = LiveByteQueue.defaultHighWatermark,
    lowWatermark: Int = LiveByteQueue.defaultLowWatermark,
    hold: @escaping @Sendable () -> Void = {},
    release: @escaping @Sendable () -> Void = {}
  ) {
    self.highWatermark = highWatermark
    self.lowWatermark = lowWatermark
    self.hold = hold
    self.release = release
  }

  var bufferedCount: Int {
    condition.lock(); defer { condition.unlock() }
    return buffered
  }

  /// Adds bytes. After the stream is over or the queue closed they are
  /// dropped: a transfer being cancelled still delivers a last few.
  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    condition.lock()
    guard outcome == nil, !isClosed else {
      condition.unlock()
      return
    }
    chunks.append(data)
    buffered += data.count
    let shouldHold = !isHeld && buffered > highWatermark
    if shouldHold { isHeld = true }
    let waiting = takeWaiters()
    condition.unlock()
    if shouldHold { hold() }
    for waiter in waiting { waiter.resume() }
  }

  /// Says how the stream is over, once; what is buffered is read first.
  func finish(_ result: Outcome) {
    condition.lock()
    if outcome == nil { outcome = result }
    let waiting = takeWaiters()
    condition.broadcast()
    condition.unlock()
    for waiter in waiting { waiter.resume() }
  }

  /// Drops what is buffered and makes every read, waiting or to come, fail as
  /// interrupted. What was held back is let go, for a transfer to be
  /// cancelled rather than left suspended.
  func close() {
    condition.lock()
    isClosed = true
    chunks.removeAll()
    headOffset = 0
    buffered = 0
    let wasHeld = isHeld
    isHeld = false
    let waiting = takeWaiters()
    condition.broadcast()
    condition.unlock()
    if wasHeld { release() }
    for waiter in waiting { waiter.resume() }
  }

  /// Ends the waits of the reads now waiting, so each looks again: one that
  /// was cancelled gives up with `.woken`, the others wait on. Reads that
  /// begin later wait as usual.
  private func wakeWaiters() {
    condition.lock()
    let waiting = takeWaiters()
    condition.unlock()
    for waiter in waiting { waiter.resume() }
  }

  /// Up to `maxLength` bytes, waiting only while there are none and the
  /// stream is not over. Bytes taken are never dropped, even by a read that
  /// was cancelled meanwhile.
  func take(maxLength: Int) async -> Taken {
    while true {
      if let taken = poll(maxLength: maxLength) { return taken }
      if Task.isCancelled { return .woken }
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          condition.lock()
          if buffered > 0 || outcome != nil || isClosed || Task.isCancelled {
            condition.unlock()
            continuation.resume()
          } else {
            waiters.append(continuation)
            condition.unlock()
          }
        }
      } onCancel: {
        wakeWaiters()
      }
    }
  }

  /// For a writer on a thread of its own: returns once the buffer is below
  /// the high watermark, or the stream is over, or the queue closed.
  func waitForRoom() {
    condition.lock()
    while buffered > highWatermark, outcome == nil, !isClosed { condition.wait() }
    condition.unlock()
  }

  private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
    let waiting = waiters
    waiters.removeAll()
    return waiting
  }

  private func poll(maxLength: Int) -> Taken? {
    condition.lock()
    if isClosed {
      condition.unlock()
      return .failure(.interrupted)
    }
    if buffered > 0, maxLength > 0 {
      let head = chunks[0]
      let count = min(maxLength, head.count - headOffset)
      let data = head.subdata(in: (head.startIndex + headOffset)..<(head.startIndex + headOffset + count))
      headOffset += count
      buffered -= count
      if headOffset == head.count {
        chunks.removeFirst()
        headOffset = 0
      }
      let shouldRelease = isHeld && buffered < lowWatermark
      if shouldRelease { isHeld = false }
      condition.broadcast()
      condition.unlock()
      if shouldRelease { release() }
      return .data(data)
    }
    let result = outcome
    condition.unlock()
    switch result {
    case .end?: return .end
    case .failure(let error)?: return .failure(error)
    case nil: return nil
    }
  }
}
