import Foundation

/// An interrupt flag any thread can read.
public final class InterruptFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false

  public init() {}

  public var isRaised: Bool {
    lock.lock()
    defer { lock.unlock() }
    return raised
  }

  public func raise() {
    lock.lock()
    defer { lock.unlock() }
    raised = true
  }
}
