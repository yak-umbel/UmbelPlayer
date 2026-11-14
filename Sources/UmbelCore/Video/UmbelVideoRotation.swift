import CoreGraphics

/// How far a picture is turned, clockwise, to be shown upright.
///
/// A phone held upright stores its picture sideways and says so beside it;
/// this is what it says. Only right angles are carried: a stream that asks
/// for a flip, or for any other angle, is shown as stored.
public enum UmbelVideoRotation: Int, Sendable, Equatable {
  case none = 0
  case clockwise90 = 90
  case clockwise180 = 180
  case clockwise270 = 270

  /// Whether width and height trade places when the picture is turned: the
  /// two quarter turns.
  public var swapsAxes: Bool { self == .clockwise90 || self == .clockwise270 }

  /// From clockwise degrees; anything but the four right angles is `.none`.
  internal init(clockwiseDegrees degrees: Int32) {
    self = UmbelVideoRotation(rawValue: Int(degrees)) ?? .none
  }

  /// The size after the turn: width and height trade places for a quarter
  /// turn.
  internal func turned(_ size: CGSize) -> CGSize {
    swapsAxes ? CGSize(width: size.height, height: size.width) : size
  }
}
