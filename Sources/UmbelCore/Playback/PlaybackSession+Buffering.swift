import CoreMedia
import Foundation

extension PlaybackSession {
  /// Content read ahead of the decoders, in seconds of the measured track.
  public var bufferedDuration: CMTime {
    get async {
      let seconds = await cache?.bufferedSeconds ?? 0
      return CMTime(seconds: seconds, preferredTimescale: 1_000)
    }
  }

  /// Compressed payload bytes queued ahead of the decoders across all tracks.
  /// Includes history moved back into the decode queues by a cached seek.
  /// Excludes backward history, decoded output, retained audio, subtitle history,
  /// and demuxer preroll.
  public var bufferedPacketBytes: Int { get async { await cache?.bufferedPacketBytes ?? 0 } }

  /// Compressed media payload retained for backward seeks. Shared across tracks;
  /// bounded by BufferingConfiguration.maximumBackwardPacketBytes. Packets
  /// transferred back to decode queues count in bufferedPacketBytes instead.
  public var backwardPacketBytes: Int { get async { await cache?.backwardPacketBytes ?? 0 } }
}
