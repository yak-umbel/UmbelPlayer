import Foundation

/// Makes an asynchronous call synchronous.
///
/// **For dedicated threads only.** The I/O callbacks beneath are synchronous
/// and sources are asynchronous; this is the one seam between them. Called
/// on Swift concurrency's cooperative pool, it would tie up a pool thread,
/// and at worst deadlock.
///
/// Blocking on purpose: data that has not arrived has not arrived, and
/// demuxing ought to wait for it.
///
/// The call runs in a task of its own, which the waiting thread's owner
/// cannot reach by cancelling theirs; `abandonment` is the way to it.
public func blockingCall<T: Sendable>(
  abandonment: ReadAbandonment? = nil,
  _ body: @escaping @Sendable () async throws -> T
) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<T>()
  let task = Task.detached(priority: .userInitiated) {
    do {
      box.set(value: try await body())
    } catch {
      box.set(error: error)
    }
    semaphore.signal()
  }
  abandonment?.begin { task.cancel() }
  semaphore.wait()
  abandonment?.end()
  return try box.take()
}

/// A version that does not throw, for queries returning optionals.
///
/// With `fallback` rather than returning `T?`: T is often optional already,
/// and another layer would make it `T??`, one more unwrap at every call.
public func blockingValue<T: Sendable>(
  default fallback: T,
  _ body: @escaping @Sendable () async -> T
) -> T {
  let semaphore = DispatchSemaphore(value: 0)
  let box = ResultBox<T>()
  Task.detached(priority: .userInitiated) {
    box.set(value: await body())
    semaphore.signal()
  }
  semaphore.wait()
  return (try? box.take()) ?? fallback
}

/// The semaphore orders the threads, so the simplest protection will do.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T?
  private var failure: Error?

  func set(value newValue: T) {
    lock.lock()
    defer { lock.unlock() }
    value = newValue
  }

  func set(error newError: Error) {
    lock.lock()
    defer { lock.unlock() }
    failure = newError
  }

  func take() throws -> T {
    lock.lock()
    defer { lock.unlock() }
    if let failure { throw failure }
    guard let value else { throw UmbelSerialWorkerError.stopped }
    return value
  }
}
