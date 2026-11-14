import UmbelFFmpegSupport

/// A run of a playlist being read: its demuxer, the segments beneath it and
/// how its streams map onto the playlist's tracks.
internal struct PlaylistRun {
  let demuxer: FFmpegDemuxer
  let segments: HLSSegmentStream
  let mapping: [Int32: UmbelTrack.ID]
  let number: Int
  let startSegment: Int
}

/// A packet read from a run, with the segment it was found in.
internal struct PlaylistPacket {
  let raw: FFmpegPacket
  let trackID: UmbelTrack.ID
  let segment: HLSSegmentStream.Location?
}
