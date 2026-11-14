import Foundation

/// A request of an HTTP source that failed, told apart by codes rather than
/// by words: the system's words for a networking error follow the device's
/// language, and a status is not a timeout.
public struct HTTPRequestFailure: Sendable, Equatable {
  /// What the request failed with; what the read throws when it was the
  /// last request the read could make.
  public let error: UmbelError
  /// The networking error's code, when the transfer failed in transit with
  /// one.
  public let urlErrorCode: URLError.Code?
  /// The system error's domain and code, when the transfer failed in
  /// transit: a networking error (`NSURLErrorDomain`, also in
  /// `urlErrorCode`) or one from below the URL layer, such as CFNetwork's.
  public let errorDomain: String?
  public let errorCode: Int?
  /// The server's status; nil when no response came.
  public let httpStatus: Int?
  /// Where the read was to start.
  public let offset: Int64
  /// Requests the read had made, this one included: 1 is the first, and
  /// each retry adds one.
  public let attempts: Int
}
