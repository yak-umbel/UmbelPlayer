import UmbelFFmpegSupport

/// Which track each stream of a run stands for.
///
/// The first run's streams are the tracks. A later run is demuxed afresh
/// and may number its streams otherwise — an ad muxed elsewhere — so its
/// streams are matched by kind and order: its n-th video stream plays as the
/// n-th video track. Streams with no counterpart are left out.
internal enum HLSStreamMapping {
  static func map(_ streams: [FFmpegStreamInfo], onto tracks: [UmbelTrack]) -> [Int32: UmbelTrack.ID] {
    var available: [UmbelTrack.Kind: [UmbelTrack.ID]] = [:]
    for track in tracks { available[track.kind, default: []].append(track.id) }
    var mapping: [Int32: UmbelTrack.ID] = [:]
    for stream in streams {
      guard let kind = TrackMapping.track(from: stream)?.kind,
            var ids = available[kind], !ids.isEmpty else { continue }
      mapping[stream.index] = ids.removeFirst()
      available[kind] = ids
    }
    return mapping
  }
}
