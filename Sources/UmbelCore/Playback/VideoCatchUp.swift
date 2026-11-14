import CoreMedia
import Foundation

/// Keeps video decoding up with the clock when it falls behind.
///
/// Dropping late frames at display alone leaves the decoder working through
/// every frame, each too late to show once it is out; slower than real time,
/// the picture falls further behind the sound without end. So two steps,
/// decided for every frame that comes out:
///
/// - Out after its time, a few frames running: the decoder skips frames no
///   other frame refers to. The rest decode as before, so nothing shown is
///   damaged, and skipping lasts until a frame comes out in time — the
///   further behind, the longer. One late frame is not falling behind:
///   frames come out unevenly, and a single late one says nothing.
/// - Over half a second late: decoding starts again from the last keyframe
///   at or before the clock, when one is buffered. Skipping alone cannot
///   catch up where every frame is a reference.
///
/// Only while the clock runs: stopped, decoding catches up by itself.
internal actor VideoCatchUp {
  internal enum Step: Equatable, Sendable { case decodeAll, skipNonReference, dropToKeyframe }

  internal static let veryLate = 0.5
  /// Late frames in a row that make falling behind.
  internal static let lateRun = 3

  private let cache: PacketCache
  private let clock: PresentationClock
  private var lateInARow = 0

  internal init(cache: PacketCache, clock: PresentationClock) {
    self.cache = cache
    self.clock = clock
  }

  /// What to do for a frame out this late, in seconds — nil while the clock
  /// stands still — after `lateInARow` late frames, this one included.
  internal static func step(forLateness lateness: Double?, lateInARow: Int) -> Step {
    guard let lateness, lateness > 0 else { return .decodeAll }
    if lateness > veryLate { return .dropToKeyframe }
    return lateInARow >= lateRun ? .skipNonReference : .decodeAll
  }

  /// Late frames in a row once a frame this late is out, after `lateInARow`
  /// before it. A frame in time — or the clock standing still — ends the run.
  internal static func lateRun(after lateInARow: Int, lateness: Double?) -> Int {
    guard let lateness, lateness > 0 else { return 0 }
    return lateInARow + 1
  }

  /// Frames just decoded from `track`: has `session` keep up with the clock.
  internal func review(
    _ frames: [VideoFrame], from session: any VideoFrameSource, track: UmbelTrack.ID
  ) async {
    guard let newest = frames.last(where: { $0.presentationTime.isValid }) else { return }
    let now = await clock.now()
    let running = await clock.rate != 0
    let lateness = running ? (now - newest.presentationTime).seconds : nil
    lateInARow = Self.lateRun(after: lateInARow, lateness: lateness)
    switch Self.step(forLateness: lateness, lateInARow: lateInARow) {
    case .decodeAll:
      await session.setSkipsNonReference(false)
    case .skipNonReference:
      await session.setSkipsNonReference(true)
    case .dropToKeyframe:
      if await cache.skipToKeyframe(of: track, atOrBefore: now) > 0 {
        await session.flush()
      }
      await session.setSkipsNonReference(true)
    }
  }

  /// A seek: what was behind belongs to where the stream was.
  internal func reset() {
    lateInARow = 0
  }
}
