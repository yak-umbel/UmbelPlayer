import Foundation

/// A dedicated serial worker thread.
///
/// Demuxing and video decoding both use one: the first because the I/O
/// callbacks beneath block, the second because decoding is heavy CPU work.
/// Neither belongs on Swift concurrency's cooperative pool, which has as many
/// threads as cores: each one blocked is one fewer, and all of them blocked
/// waiting on another task is a deadlock. A thread of our own rules that out
/// entirely — what blocks is ours, at a known, bounded cost.
public final class SerialWorkerThread: @unchecked Sendable {
  private enum State {
    case running
    case stopped
  }

  /// A queued piece of work. Shutting down has to be able to **cancel** it
  /// rather than run it in place: run in place, it would run on the thread
  /// calling shutdown, breaking thread affinity — which is this type's whole
  /// reason to exist.
  private struct WorkItem {
    let run: @Sendable () -> Void
    let cancel: @Sendable () -> Void
  }

  private let condition = NSCondition()
  private var queue: [WorkItem] = []
  private var state: State = .running
  private var thread: Thread?

  public init(name: String) {
    let thread = Thread { [weak self] in
      self?.loop()
    }
    thread.name = name
    thread.stackSize = 512 * 1024
    self.thread = thread
    thread.start()
  }

  deinit {
    shutdown()
  }

  /// Runs `body` on the dedicated thread and hands the result back.
  public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let box = ContinuationBox(continuation)
      let item = WorkItem(
        run: {
          do {
            box.finish(returning: try body())
          } catch {
            box.finish(throwing: error)
          }
        },
        cancel: {
          box.finish(throwing: UmbelSerialWorkerError.stopped)
        }
      )
      condition.lock()
      guard state == .running else {
        condition.unlock()
        item.cancel()
        return
      }
      queue.append(item)
      condition.signal()
      condition.unlock()
    }
  }

  /// Stops the thread. Can be called again. Work queued but not yet run is
  /// **cancelled** (ends with an error), not run in place — it would run on
  /// the caller's thread.
  public func shutdown() {
    condition.lock()
    guard state == .running else {
      condition.unlock()
      return
    }
    state = .stopped
    let pending = queue
    queue.removeAll()
    condition.broadcast()
    condition.unlock()
    // Work not run must still end, or its caller waits for good.
    for item in pending { item.cancel() }
  }

  private func loop() {
    while true {
      condition.lock()
      while queue.isEmpty && state == .running {
        condition.wait()
      }
      if state == .stopped && queue.isEmpty {
        condition.unlock()
        return
      }
      let item = queue.removeFirst()
      condition.unlock()
      item.run()
    }
  }
}

/// Makes sure a continuation is resumed exactly once. In a race both run and
/// cancel may fire, and resuming a continuation twice crashes at run time —
/// not something to shrug off.
///
/// Two methods rather than one taking a Result: the Error in Result<T, Error>
/// is not Sendable, and stored in a property then taken out for the
/// continuation, strict concurrency checking cannot prove it has one owner
/// and reports "sending risks causing data races".
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = continuation
  }

  func finish(returning value: T) {
    guard let pending = take() else { return }
    pending.resume(returning: value)
  }

  func finish(throwing error: Error) {
    guard let pending = take() else { return }
    pending.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<T, Error>? {
    lock.lock()
    defer { lock.unlock() }
    let pending = continuation
    continuation = nil
    return pending
  }
}

public enum UmbelSerialWorkerError: Error, Sendable {
  case stopped
}
