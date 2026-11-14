import CoreMedia
import Foundation

/// The steps of one seek, for the session that decides when one runs and
/// which is the latest.
///
/// When complete cached packets cover the target (`PlaybackPipeline.seekUsingCache`):
/// reading goes on where it is, and only decoding and the outputs start
/// again — nothing is requested twice, and the level stays. Otherwise reading
/// stops, the cache is emptied and the demuxer moves to the target.
internal struct PlaybackSeek {
  let target: CMTime
  let pipeline: PlaybackPipeline?
  let cache: PacketCache?
  let audio: AudioPath
  let subtitles: SubtitleController
  let clock: PresentationClock
  let audioOutput: (any AudioOutput)?
  let videoRenderer: (any VideoRenderer)?
  let videoDecodeSession: (any VideoFrameSource)?
  let diagnostics: UmbelPlaybackDiagnostics?
  /// False during a picture transition or a reread required by track coverage.
  let mayKeepCache: Bool
  /// Whether this seek is still the latest; asked after every wait.
  let isCurrent: @Sendable () async -> Bool
  /// Publishes the session's routing, and with it the seek generation.
  let reroute: @Sendable () async -> Void

  func run() async throws {
    var keepingCache = mayKeepCache
    while await isCurrent() {
      if try await attempt(keepingCache: keepingCache) { return }
      // A source or delay changed across an await. Any moved queues are
      // discarded by the ordinary seek before decoding starts again.
      keepingCache = false
    }
  }

  /// False means the subtitle assumptions changed; repeat with a normal seek.
  private func attempt(keepingCache: Bool) async throws -> Bool {
    // The generation is up already, so the running tasks see themselves as
    // stale as soon as the routing says so; then they stop. Stopping flushes
    // the sinks, and that is what releases a feeder parked on backpressure —
    // cancellation alone cannot, since withCheckedContinuation does not
    // observe it. Reading goes on until it is clear what it read goes.
    await reroute()
    await pipeline?.stopFeeding()
    guard await isCurrent() else { return true }
    let snapshot = await subtitles.replaySnapshot(at: target)
    let result = keepingCache
      ? await pipeline?.seekUsingCache(to: target, subtitleRequirements: snapshot.requirements)
        ?? .miss("noPipeline")
      : .miss("cacheBypassed")
    guard await isCurrent() else { return true }
    guard await subtitles.isCurrent(snapshot) else { return false }
    let kept = result.kept
    var values = ["target": target.seconds, "bufferedSeconds": await cache?.bufferedSeconds ?? 0,
                  "backwardPacketBytes": Double(await cache?.backwardPacketBytes ?? 0)]
    if let spans = await cache?.queueSpans {
      for (track, span) in spans {
        values["queue\(track.rawValue)From"] = span.lowerBound
        values["queue\(track.rawValue)To"] = span.upperBound
      }
    }
    var soundFrom: CMTime?
    if !kept {
      soundFrom = try await reread()
      guard await isCurrent() else { return true }
    }

    await audio.prepareSeek(to: target, keeping: kept)
    await videoDecodeSession?.flush()
    // Forward reuse keeps decoded cues; replay restores compressed subtitle
    // history because the old decoded cues may have been pruned already.
    if !kept || result.replaysHistory { await subtitles.flushEmbedded() }
    // Once more: woken feeding may still hold a frame and put it in the queue
    // just emptied — the flash of the old picture after a seek.
    await videoRenderer?.flush()
    await audioOutput?.flush()
    guard await isCurrent() else { return true }

    // No prepare: the format is the same, and flush did not close the device.

    // Seeking into the content, the last run's "ended" no longer holds.
    await pipeline?.clearTerminal()
    await clock.reset(to: target)
    await pipeline?.armDiscardBoth(at: target)
    if !kept { await pipeline?.armPreroll(at: target, audioFrom: soundFrom) }

    // No restart of the output here: the cache holds the pipeline back until
    // it has enough, and it starts the output itself once the first frames are in.
    await reroute()
    guard await isCurrent() else { return true }
    guard await subtitles.isCurrent(snapshot) else { return false }
    diagnostics?.record("session_seek_path", values: values,
                        labels: ["path": kept ? "cache" : "reread", "cache": result.label])
    await pipeline?.start()
    return true
  }

  /// Stops reading, empties the cache and moves the demuxer to the target —
  /// or before it, for the sound the system player plays and for the
  /// subtitle showing there. Returns where the sound is read from, if not
  /// from the target.
  private func reread() async throws -> CMTime? {
    await pipeline?.stop()
    await pipeline?.flushCache()
    guard await isCurrent() else { return nil }
    // The system player wants whole segments of sound from before the target.
    let soundFrom = await audio.readingStart(forSeekTo: target)
    do {
      // Reading may start earlier so the subtitle showing at the target gets
      // read too; the pipeline's preroll filter keeps that from costing decoding.
      try await subtitles.positionDemuxer(for: soundFrom.map { min(target, $0 - AudioPath.demuxLead) } ?? target)
    } catch {
      // Cut short for a later seek, which settles how this ends.
      guard await isCurrent() else { return nil }
      await pipeline?.markFailed(error)
      throw error
    }
    return soundFrom
  }
}

/// Internal outcome; existing diagnostics retain their cache/reread path label.
internal enum CacheSeekResult {
  case forward
  case backward
  case miss(String)

  var kept: Bool {
    if case .miss = self { return false }
    return true
  }
  var replaysHistory: Bool {
    if case .backward = self { return true }
    return false
  }
  var label: String {
    switch self {
    case .forward: return "forward"
    case .backward: return "backward"
    case .miss(let reason): return reason
    }
  }
}
