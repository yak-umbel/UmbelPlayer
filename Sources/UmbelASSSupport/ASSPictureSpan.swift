import Foundation
import LibASS

/// A stretch of time over which the events on screen stay the same.
public struct ASSPictureSpan: Sendable, Equatable {
  /// First millisecond of the stretch; nil when it reaches back for good.
  public let start: Int64?
  /// First millisecond after it; nil when no event known now would end it.
  public let end: Int64?
  /// Whether an event on screen changes with time by itself.
  public let isAnimated: Bool

  public func contains(_ time: Int64) -> Bool {
    (start.map { time >= $0 } ?? true) && (end.map { time < $0 } ?? true)
  }

  /// Whether an event with these times would be on screen at some moment
  /// of the stretch: one that does changes the picture drawn for it.
  public func overlaps(eventStart: Int64, duration: Int64) -> Bool {
    duration > 0
      && (end.map { eventStart < $0 } ?? true)
      && (start.map { eventStart + duration > $0 } ?? true)
  }
}

extension ASSTrack {
  /// The stretch of time around `time` in which the same events are on
  /// screen, as far as the events read so far tell.
  ///
  /// A line is on screen from its start up to, not including, its end. The
  /// stretch is bounded by the latest of those moments at or before `time`
  /// and the earliest after it, so no line starts or ends inside it. Lines
  /// with no duration are never on screen and bound nothing.
  public func pictureSpan(at time: Int64) -> ASSPictureSpan {
    let track = pointer.pointee
    var start: Int64?
    var end: Int64?
    var isAnimated = false
    for index in 0..<Int(track.n_events) {
      let event = track.events[index]
      guard event.Duration > 0 else { continue }
      let from = Int64(event.Start)
      let until = from + Int64(event.Duration)
      if until <= time {
        start = max(start ?? until, until)
      } else if from > time {
        end = min(end ?? from, from)
      } else {
        start = max(start ?? from, from)
        end = min(end ?? until, until)
        isAnimated = isAnimated || ASSEventAnimation.changesWithTime(
          effect: event.Effect, text: event.Text)
      }
    }
    return ASSPictureSpan(start: start, end: end, isAnimated: isAnimated)
  }
}
