import CoreMedia
import Foundation

/// A host clock that can be swapped in.
///
/// It exists so that `PresentationClock.now()` is a pure function: given an
/// anchor, the host time and a rate, the result is fixed. Tests can then put
/// in a clock they control, run ten minutes in milliseconds and check the
/// drift — and audio/video drift accumulates; ten seconds of listening would
/// not catch it.
public protocol HostTimeSource: Sendable {
  var now: CMTime { get }
}

/// The real one: reads the system's host clock.
public struct SystemHostTimeSource: HostTimeSource {
  public init() {}

  public var now: CMTime {
    CMClockGetTime(CMClockGetHostTimeClock())
  }
}
