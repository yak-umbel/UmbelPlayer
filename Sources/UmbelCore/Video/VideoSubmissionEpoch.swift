import Foundation

/// Serializes flush against completion handlers submitting to a display sink.
internal final class VideoSubmissionEpoch: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 0
  var value: UInt64 { lock.withLock { generation } }
  func advance() { lock.withLock { generation &+= 1 } }
  func withCurrent(_ value: UInt64, _ submit: () -> Void) {
    lock.withLock { if generation == value { submit() } }
  }
}
