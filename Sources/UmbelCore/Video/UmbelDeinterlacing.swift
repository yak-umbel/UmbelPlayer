import Foundation

/// Whether interlaced video is made progressive.
public enum UmbelDeinterlacing: Sendable, Equatable {
  /// Frames the stream marks as interlaced become two progressive pictures,
  /// one per field, half a frame apart. The default.
  case automatic
  /// Every frame is shown as decoded: interlaced ones woven, combed where
  /// the picture moves.
  case off
}

/// The session's choice, read by the decoding engine for every frame, on
/// whatever thread decoding runs on.
internal final class DeinterlaceSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var current: UmbelDeinterlacing

  init(_ mode: UmbelDeinterlacing = .automatic) { current = mode }

  var mode: UmbelDeinterlacing {
    get { lock.withLock { current } }
    set { lock.withLock { current = newValue } }
  }
}
