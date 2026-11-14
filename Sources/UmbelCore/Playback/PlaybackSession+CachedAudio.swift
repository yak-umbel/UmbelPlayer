import CoreMedia
import Foundation

extension PlaybackSession {
  /// Media-time intervals represented by retained compressed packets.
  /// Empty until playback has read packets for this audio track.
  public func cachedAudioRanges(for track: UmbelTrack.ID) async -> [CMTimeRange] {
    await cache?.cachedAudioRanges(for: track) ?? []
  }

  /// Decodes retained packets independently of the playback decoder and
  /// source. The requested interval must be covered by compressed packets.
  public func extractCachedAudio(
    for track: UmbelTrack.ID, range: CMTimeRange
  ) async throws -> CachedAudioExtraction {
    try Task.checkCancellation()
    guard let cache else {
      throw CachedAudioError.missingCoverage(available: [])
    }
    let snapshot = try await cache.snapshotAudio(for: track, range: range)
    return try await CachedAudioExtractor.extract(snapshot)
  }
}

internal enum CachedAudioExtractor {
  static func extract(_ snapshot: AudioPacketSnapshot) async throws -> CachedAudioExtraction {
    try Task.checkCancellation()
    let decoder: AudioDecodeSession
    do {
      decoder = AudioDecodeSession(decoder: try snapshot.parameters.makeAudioDecoder())
    } catch {
      throw CachedAudioError.decoderUnavailable
    }
    do {
      var frames: [AudioFrame] = []
      var retainedBytes = 0
      func collect(_ decoded: [AudioFrame]) throws {
        for frame in decoded {
          guard let trimmed = frame.trimmed(to: snapshot.requestedRange) else { continue }
          let sampleBytes = MemoryLayout<Float>.stride
          guard trimmed.samples.count <= (snapshot.maxDecodedBytes - retainedBytes) / sampleBytes else {
            throw CachedAudioError.outputLimitExceeded(maxBytes: snapshot.maxDecodedBytes)
          }
          retainedBytes += trimmed.samples.count * sampleBytes
          frames.append(trimmed)
        }
      }
      for packet in snapshot.packets {
        try Task.checkCancellation()
        let decoded = try await decoder.decode(packet)
        try collect(decoded)
      }
      try Task.checkCancellation()
      let held = try await decoder.drain()
      try collect(held)
      try Task.checkCancellation()
      await decoder.close()
      guard !frames.isEmpty else { throw CachedAudioError.noDecodableSamples }
      return CachedAudioExtraction(frames: frames)
    } catch {
      await decoder.close()
      throw error
    }
  }
}
