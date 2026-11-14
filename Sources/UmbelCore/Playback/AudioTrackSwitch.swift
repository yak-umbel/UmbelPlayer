import CoreMedia
import Foundation

/// The steps of switching the sound to another track, or silencing it, for
/// the session that asks for one; see `PlaybackSession.selectAudioTrack(_:)`.
///
/// They run on the session's actor, so what it holds changes between them
/// only across their waits, as if they were written in the session itself.
internal struct AudioTrackSwitch {
  let id: UmbelTrack.ID?
  let clock: PresentationClock
  let demux: DemuxSession

  func run(in session: isolated PlaybackSession) async throws {
    guard !session.isStopped else { return }
    guard id != session.audioTrack?.id else { return }   // idempotent; keeps the output
    let subtitleRevision = await session.subtitles.replayRevision

    guard let id else {
      // Sound off: the clock loses its authority and falls back to host time.
      _ = try await session.audio.select(nil, at: await session.currentTime)
      session.audioTrack = nil
      await clock.setAuthority(.host)
      try? await session.subtitles.followAudio(nil)
      await session.pushRouting()
      try await session.recoverSubtitleCoverage(since: subtitleRevision)
      return
    }

    // Made before the old way is taken down: a failure leaves the old.
    let (track, rereads) = try await session.audio.select(trackWithID: id, at: await session.currentTime)
    session.audioTrack = track
    await clock.setAuthority(.audio)

    // A switch drops queued sound and continues at the demuxer's position;
    // what the cache discarded of the new track past here is read again.
    try? await session.subtitles.followAudio(track)
    await session.pushRouting()
    let now = await session.currentTime
    let lost = await session.cache?.dropped(id, after: now) == true
    let seekable = await demux.isSeekable
    if rereads || (lost && seekable) {
      try await session.seek(to: now)
      try await session.recoverSubtitleCoverage(since: subtitleRevision)
    } else {
      try await session.recoverSubtitleCoverage(since: subtitleRevision)
      try await session.pipeline?.restartOutputIfRunning()
    }
  }
}
