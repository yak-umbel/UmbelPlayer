import Foundation

/// Counts observed activity for one HTTP source. Bytes received are delegate
/// callbacks, not socket traffic; buffered bytes are unread response bytes.
public struct HTTPTransferStatistics: Sendable, Equatable {
  public let requestCount: Int64
  public let receivedBytes: Int64
  public let deliveredBytes: Int64
  public let bufferedBytes: Int64
  /// Times a timeout this source met moved requests to a fresh session.
  public let sessionRenewals: Int64
}

final class HTTPTransferMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: Int64 = 0
  private var received: Int64 = 0
  private var delivered: Int64 = 0
  private var buffered: Int64 = 0
  private var renewals: Int64 = 0

  var snapshot: HTTPTransferStatistics {
    lock.lock(); defer { lock.unlock() }
    return .init(requestCount: requests, receivedBytes: received,
                 deliveredBytes: delivered, bufferedBytes: buffered,
                 sessionRenewals: renewals)
  }

  func opened() {
    lock.lock(); defer { lock.unlock() }
    requests = Self.adding(requests, 1)
  }

  func received(_ count: Int) {
    lock.lock(); defer { lock.unlock() }
    received = Self.adding(received, Int64(count))
  }

  func buffered(_ count: Int) {
    lock.lock(); defer { lock.unlock() }
    if count >= 0 {
      buffered = Self.adding(buffered, Int64(count))
    } else {
      buffered = max(0, buffered + Int64(count))
    }
  }

  func renewedSession() {
    lock.lock(); defer { lock.unlock() }
    renewals = Self.adding(renewals, 1)
  }

  func delivered(_ count: Int) {
    lock.lock(); defer { lock.unlock() }
    delivered = Self.adding(delivered, Int64(count))
  }

  private static func adding(_ current: Int64, _ count: Int64) -> Int64 {
    let (sum, overflow) = current.addingReportingOverflow(count)
    return overflow ? Int64.max : sum
  }
}
