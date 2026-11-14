import Foundation

/// The bytes of one stream off the network, read by FFmpeg.
///
/// Every call but `requestInterrupt()` blocks, and has to be made from one
/// thread: a thread of the caller's own, not the cooperative pool. What ends a
/// call from outside is the interrupt, which FFmpeg polls while it waits; it
/// is also how the deadlines are kept.
public protocol FFmpegByteReading: AnyObject, Sendable {
  /// Makes every call now blocked, and every one after, end as
  /// `FFmpegStreamFailure.interrupted`. Callable from any thread.
  func requestInterrupt()
  /// Connects. Everything the first exchange with the peer needs is within
  /// the connect deadline.
  func open() throws
  /// Up to `maxLength` bytes, waiting while there are none; empty means the
  /// stream ended. Failures are `FFmpegStreamFailure`.
  func read(maxLength: Int) throws -> Data
  /// Lets the connection go. Not while another thread is in a call.
  func close()
}

public enum FFmpegStreamFailure: Error, Equatable, Sendable {
  public enum Phase: Equatable, Sendable { case connecting, receiving }

  /// `requestInterrupt()` was called.
  case interrupted
  /// A deadline passed.
  case timedOut(Phase)
  /// FFmpeg's own error.
  case failed(FFmpegErrorCode)
}

/// What the interrupt callback looks at: a request from outside, and the
/// deadline of the call being made.
final class InterruptState: @unchecked Sendable {
  private let lock = NSLock()
  private var requested = false
  private var abandoned = false
  private var deadline: UInt64 = 0
  private var expired = false

  private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  var isRequested: Bool {
    lock.lock(); defer { lock.unlock() }
    return requested
  }

  /// Whether the call was abandoned since the last `arm`.
  var wasAbandoned: Bool {
    lock.lock(); defer { lock.unlock() }
    return abandoned
  }

  /// Whether a deadline has passed since the last `arm`.
  var hasExpired: Bool {
    lock.lock(); defer { lock.unlock() }
    return expired
  }

  func request() {
    lock.lock(); requested = true; lock.unlock()
  }

  /// Ends the call now blocked, and no other: unlike `request()` it is for
  /// this call only, and the next begins without it.
  func abandon() {
    lock.lock(); abandoned = true; lock.unlock()
  }

  func arm(after seconds: TimeInterval) {
    lock.lock()
    deadline = Self.now() &+ UInt64(max(0, seconds) * 1_000_000_000)
    expired = false
    abandoned = false
    lock.unlock()
  }

  func disarm() {
    lock.lock(); deadline = 0; lock.unlock()
  }

  func shouldInterrupt() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if requested || abandoned { return true }
    if deadline != 0, Self.now() >= deadline {
      expired = true
      return true
    }
    return false
  }

  /// What a failed call was, once it has failed: the host's stop first, then a
  /// deadline, else FFmpeg's own error.
  func failure(for code: Int32, during phase: FFmpegStreamFailure.Phase) -> FFmpegStreamFailure {
    if isRequested || wasAbandoned { return .interrupted }
    if hasExpired { return .timedOut(phase) }
    return .failed(FFmpegErrorCode.classify(code))
  }
}
