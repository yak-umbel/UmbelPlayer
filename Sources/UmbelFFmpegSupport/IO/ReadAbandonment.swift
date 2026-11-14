import Foundation

/// Lets the read a demuxer is blocked in be given up from another thread,
/// without closing anything: the next read, once reading is allowed again,
/// goes to the same source as before.
///
/// A read is cancelled the way any task is — the source is asked to stop
/// through cancellation — so a source that follows cancellation ends it at
/// once, and one that does not ends it when it would have anyway. Until
/// `resume()` every read that begins is cancelled as it starts: stopping a
/// reader is not over until it has really stopped, and a read it began just
/// before must not escape.
public final class ReadAbandonment: @unchecked Sendable {
  private let lock = NSLock()
  private var current: (@Sendable () -> Void)?
  private var isAbandoning = false

  public init() {}

  /// Gives up the read under way, and any that begins before `resume()`.
  public func abandon() {
    lock.lock()
    isAbandoning = true
    let cancel = current
    lock.unlock()
    cancel?()
  }

  /// Reads go on as usual again.
  public func resume() {
    lock.lock()
    isAbandoning = false
    lock.unlock()
  }

  /// A read begins: `cancel` ends it.
  func begin(_ cancel: @escaping @Sendable () -> Void) {
    lock.lock()
    if isAbandoning {
      lock.unlock()
      cancel()
      return
    }
    current = cancel
    lock.unlock()
  }

  /// The read is over.
  func end() {
    lock.lock()
    current = nil
    lock.unlock()
  }
}
