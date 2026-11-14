import Foundation
import UmbelFFmpegSupport

extension PlaybackPipeline {
  /// The pipeline for `tracks` once chosen, and the cache it reads ahead
  /// into: measured by `audioTrack` until routing says otherwise, keeping
  /// every audio track's parameters for extracting retained sound.
  ///
  /// Settings that can change meanwhile — rate, audio delay, whether the
  /// sound is ready — are for the caller to hand over once it holds the
  /// pipeline: read before, a change on the way would be lost.
  static func assembled(
    demux: DemuxSession, tracks: [UmbelTrack], audioTrack: UmbelTrack.ID?,
    audioOutput: (any AudioOutput)?, videoRenderer: (any VideoRenderer)?, clock: PresentationClock,
    buffering: BufferingConfiguration, cachedAudio: CachedAudioConfiguration,
    diagnostics: UmbelPlaybackDiagnostics? = nil
  ) async -> (pipeline: PlaybackPipeline, cache: PacketCache) {
    var audioParameters: [UmbelTrack.ID: FFmpegCodecParameters] = [:]
    let audioTracks = tracks.filter { $0.kind == .audio }
    for track in audioTracks { audioParameters[track.id] = await demux.codecParameters(for: track.id) }
    let cache = PacketCache(
      configuration: buffering, measuredTrack: audioTrack,
      videoTracks: Set(tracks.filter { $0.kind == .video }.map(\.id)),
      subtitleTracks: Set(tracks.filter { $0.kind == .subtitle }.map(\.id)),
      audioTracks: Set(audioTracks.map(\.id)), cachedAudio: cachedAudio, audioParameters: audioParameters)
    let pipeline = PlaybackPipeline(
      demux: demux, audioOutput: audioOutput, videoRenderer: videoRenderer, clock: clock, cache: cache,
      diagnostics: diagnostics)
    return (pipeline, cache)
  }
}
