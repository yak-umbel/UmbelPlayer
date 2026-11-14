import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Demuxes a media playlist a run at a time: each run's segments are one
/// stream in order, read by a demuxer of its own, its timestamps moved onto
/// the playlist's timeline. A live playlist plays on as it grows, and does
/// not seek.
///
/// A run to itself because a run can differ from the one before in every
/// way that matters to a demuxer — spliced ads were measured with another
/// picture size, another sample rate and timestamps starting over — and
/// because its start is the one place the timeline can be anchored exactly.
internal actor PlaylistDemuxer {
  /// Segments that cannot be had, one after another, before playback gives
  /// up. One or two are passed over: often an ad on a server long gone.
  static let lostSegmentsTolerated = 3

  /// Corroboration is short, even when a rendition has missing timestamps.
  private static let maximumBoundaryPackets = 512
  private static let maximumBoundaryBytes = 8 * 1_024 * 1_024

  private let segments: any HLSSegmentSource
  /// The whole list, when it is fixed; nil when live.
  private let fixed: HLSMediaPlaylist?
  private let open: @Sendable (URL) async -> any UmbelRandomAccessSource
  private let configuration: FFmpegDemuxerConfiguration
  private let keys: HLSKeys
  /// Where a read blocked in a segment is given up, for every run's demuxer.
  private let readAbandonment = ReadAbandonment()

  private(set) var tracks: [UmbelTrack] = []
  private var run: PlaylistRun?
  private var nextIndex = 0
  private var continuing = false
  private var timeline: HLSRunTimeline
  private let diagnostics: UmbelPlaybackDiagnostics?
  /// What each track's packets decode with. Kept as the same object while
  /// runs agree, so decoders are made again only when they differ.
  private var parameters: [UmbelTrack.ID: FFmpegCodecParameters] = [:]
  private var lostInARow = 0
  /// Packets read ahead of the caller, after a seek.
  private var held: [DemuxPacket] = []
  private var recovery: HLSTimestampRecovery?
  private var pending: [PlaylistPacket] = []
  private var pendingBytes = 0
  private var locations: [Int32: HLSSegmentStream.Location] = [:]
  /// The seek under way. A later one cancels it, cuts its reading short and
  /// waits for it to unwind before reading from its own target.
  private var seeking: Task<Void, Error>?
  /// The run being opened, which a later seek or `close()` cuts short.
  private var opening: HLSSegmentStream?

  nonisolated let isLive: Bool

  init(
    playlist: any HLSSegmentSource,
    open: @escaping @Sendable (URL) async -> any UmbelRandomAccessSource,
    configuration: FFmpegDemuxerConfiguration,
    diagnostics: UmbelPlaybackDiagnostics? = nil
  ) {
    self.segments = playlist
    self.fixed = playlist as? HLSMediaPlaylist
    self.isLive = !(playlist is HLSMediaPlaylist)
    self.open = open
    self.configuration = configuration
    self.diagnostics = diagnostics
    self.timeline = HLSRunTimeline(diagnostics: diagnostics)
    self.keys = HLSKeys(open: open)
  }

  /// Gives up the read a segment is being waited on in, and any that begins
  /// before `resumeReading()`; see `DemuxSession.abandonReading()`.
  nonisolated func abandonReading() { readAbandonment.abandon() }
  nonisolated func resumeReading() { readAbandonment.resume() }

  var duration: CMTime {
    fixed.map { CMTime(seconds: $0.duration, preferredTimescale: 1_000_000) } ?? .indefinite
  }

  /// Opens the first run, which has to open: a playlist whose first run is
  /// not what its tags say it is is played by the fallback, not passed over
  /// segment by segment.
  func open() async throws {
    if let first = try await segments.segment(at: 0), first.map == nil, first.key == nil {
      // Sound alone is no transport stream: to the fallback at once.
      let source = await open(first.url)
      let head = try await source.read(offset: first.byteRange?.lowerBound ?? 0, maxLength: 16)
      await source.invalidate()
      if HLSPackedAudio.isPackedAudio(head) {
        throw UmbelError.unsupportedContainer("a playlist of sound alone")
      }
    }
    try await openRun(firstOnly: true)
  }

  func nextPacket() async throws -> DemuxPacket? {
    try Task.checkCancellation()
    if !held.isEmpty { return held.removeFirst() }
    while true {
      try Task.checkCancellation()
      guard let current = run else {
        guard try await segments.segment(at: nextIndex) != nil else { return nil }
        try await openRun()
        continue
      }
      guard let raw = try await current.demuxer.readPacket() else {
        if !pending.isEmpty {
          recovery?.abandon()
          releasePending(in: current)
          return held.removeFirst()
        }
        try await endRun()
        continue
      }
      guard let trackID = current.mapping[raw.streamIndex] else { continue }
      let positioned = if let position = raw.bytePosition {
        await current.segments.segment(containing: position)
      } else { nil as HLSSegmentStream.Location? }
      if let positioned { locations[raw.streamIndex] = positioned }
      // TS audio parsers split a PES into packets; only its first has a position.
      let location = positioned ?? (recovery != nil ? locations[raw.streamIndex] : nil)
      let located = PlaylistPacket(raw: raw, trackID: trackID, segment: location)
      if let boundary = pending.first?.segment?.index, let location, location.index > boundary {
        recovery?.abandon()
        releasePending(in: current)
      }
      let decode = TrackMapping.time(ticks: raw.dts, num: raw.timeBaseNum, den: raw.timeBaseDen)
      let duration = TrackMapping.time(ticks: raw.duration, num: raw.timeBaseNum, den: raw.timeBaseDen)
      let decision = recovery?.observe(
        track: raw.streamIndex, decode: decode.seconds, duration: duration.seconds, segment: location,
        positioned: positioned != nil) ?? .unchanged
      if decision == .waiting || !pending.isEmpty {
        pending.append(located)
        pendingBytes += raw.data.count
        switch decision {
        case .corrected(let segment, let correction):
          timeline.correct(by: correction, startingAt: segment)
          releasePending(in: current)
        case .unchanged:
          releasePending(in: current)
        case .waiting:
          if pending.count >= Self.maximumBoundaryPackets || pendingBytes >= Self.maximumBoundaryBytes {
            recovery?.abandon()
            diagnostics?.record("hls_recovery_abandoned", values: [
              "packets": Double(pending.count), "bytes": Double(pendingBytes)], labels: ["reason": "limit"])
            releasePending(in: current)
          }
        }
      } else {
        if case .corrected(let segment, let correction) = decision {
          timeline.correct(by: correction, startingAt: segment)
        }
        held.append(packet(from: located, run: current))
      }
      if !held.isEmpty { return held.removeFirst() }
    }
  }

  /// To the segment the target is in; the exact seek above decodes on from
  /// there. A segment that does not start on a keyframe before the target
  /// is backed off from once, to the one before.
  ///
  /// Seeks run one at a time, the last one winning. Each opens a demuxer of
  /// its own, so one arriving while another still opens would otherwise
  /// interleave with it: two runs open, the earlier target read on. A seek
  /// superseded that way returns without error; the later one reads.
  func seek(to time: CMTime) async throws {
    guard let fixed else { throw UmbelError.seekUnsupported }
    let earlier = seeking
    earlier?.cancel()
    let work = Task {
      if let earlier {
        await cutReadingShort()
        _ = try? await earlier.value
      }
      try Task.checkCancellation()
      try await reposition(in: fixed, at: max(0, time.seconds))
    }
    seeking = work
    defer { if seeking == work { seeking = nil } }
    do {
      try await work.value
    } catch where work.isCancelled {
      diagnostics?.record("demux_seek_superseded", values: ["target": time.seconds])
    }
  }

  /// Ends the reads an earlier seek waits on, opening a run or looking in
  /// it for a keyframe: a slow network would otherwise hold the later one.
  private func cutReadingShort() async {
    await opening?.invalidate()
    await run?.segments.invalidate()
  }

  private func reposition(in fixed: HLSMediaPlaylist, at target: Double) async throws {
    var index = fixed.segmentIndex(at: target)
    for attempt in 0..<2 {
      await closeRun()
      held.removeAll()
      nextIndex = index
      continuing = false
      lostInARow = 0
      try await openRun()
      guard attempt == 0, index > 0,
            let keyframe = try await firstVideoKeyframe(),
            keyframe.presentationTime.seconds > target else { return }
      index -= 1
    }
  }

  func codecParameters(for trackID: UmbelTrack.ID) -> FFmpegCodecParameters? {
    parameters[trackID]
  }

  func makeAudioDecoder(for trackID: UmbelTrack.ID) throws -> FFmpegAudioDecoder {
    guard let parameters = parameters[trackID] else {
      throw UmbelError.trackUnavailable("track \(trackID.rawValue) is not in the playlist")
    }
    return try parameters.makeAudioDecoder()
  }

  func makeVideoDecoder(
    for trackID: UmbelTrack.ID, preferHardware: Bool, softwareThreadCount: Int32
  ) throws -> FFmpegVideoDecoder {
    guard let parameters = parameters[trackID] else {
      throw UmbelError.trackUnavailable("track \(trackID.rawValue) is not in the playlist")
    }
    return try parameters.makeVideoDecoder(
      preferHardware: preferHardware, softwareThreadCount: softwareThreadCount)
  }

  func makeSubtitleDecoder(for trackID: UmbelTrack.ID) async throws -> FFmpegSubtitleDecoder {
    guard let current = run,
          let stream = current.mapping.first(where: { $0.value == trackID })?.key else {
      throw UmbelError.trackUnavailable("track \(trackID.rawValue) is not in the playlist")
    }
    return try await current.demuxer.makeSubtitleDecoder(streamIndex: stream)
  }

  func close() async {
    seeking?.cancel()
    // First: a run's read may be waiting on a live list for its next segment.
    await segments.cancel()
    await opening?.invalidate()
    await closeRun()
  }

  // ── Runs ───────────────────────────────────────────

  /// Opens the run `nextIndex` is in. A run that will not open — its first
  /// segment lost, or not the format it should be — counts as a lost
  /// segment and is passed over.
  private func openRun(firstOnly: Bool = false) async throws {
    while let first = try await segments.segment(at: nextIndex) {
      let stream = HLSSegmentStream(
        segments: segments, startingAt: nextIndex, open: open, keys: keys, diagnostics: diagnostics)
      var reading = configuration
      // Fragmented MP4 comes with its headers apart; the rest is a
      // transport stream.
      reading.formatName = first.map == nil ? "mpegts" : "mp4"
      let demuxer = FFmpegDemuxer(
        callbacks: Self.callbacks(for: stream), configuration: reading, abandonment: readAbandonment)
      opening = stream
      defer { opening = nil }
      do {
        try await demuxer.open()
      } catch {
        await demuxer.close()
        await stream.invalidate()
        // Cut short for a later seek, or by closing: no segment was lost.
        if firstOnly || Task.isCancelled { throw error }
        let lost = await stream.failure?.segmentIndex ?? nextIndex
        try lose(lost, error)
        continue
      }
      let streams = await demuxer.streams()
      if tracks.isEmpty { tracks = streams.compactMap(TrackMapping.track(from:)) }
      let mapping = HLSStreamMapping.map(streams, onto: tracks)
      for (stream, trackID) in mapping {
        guard let fresh = await demuxer.codecParameters(streamIndex: stream) else { continue }
        if let known = parameters[trackID], known.isSameFormat(as: fresh) { continue }
        parameters[trackID] = fresh
      }
      if Task.isCancelled {
        await demuxer.close()
        await stream.invalidate()
        throw CancellationError()
      }
      timeline.beginRun(startingAt: first.start, continuing: continuing)
      let kinds = Dictionary(uniqueKeysWithValues: mapping.compactMap { stream, id in
        tracks.first { $0.id == id }.map { (stream, $0.kind) }
      })
      recovery = fixed != nil && first.map == nil
        && kinds.values.contains(.audio) && kinds.values.contains(.video)
        ? HLSTimestampRecovery(tracks: kinds) : nil
      locations.removeAll(keepingCapacity: true)
      diagnostics?.record("hls_run_open", values: [
        "run": Double(first.run), "startSegment": Double(nextIndex), "runStart": first.start],
        labels: ["continuing": String(continuing)])
      run = PlaylistRun(demuxer: demuxer, segments: stream, mapping: mapping, number: first.run, startSegment: nextIndex)
      return
    }
  }

  private func endRun() async throws {
    guard let current = run else { return }
    run = nil
    await current.demuxer.close()
    if await current.segments.completedSegments > 0 { lostInARow = 0 }
    if let failure = await current.segments.failure {
      try lose(failure.segmentIndex, failure.error)
    } else {
      nextIndex = await current.segments.nextIndex
      continuing = true
    }
  }

  private func closeRun() async {
    recovery = nil
    pending.removeAll(keepingCapacity: true)
    pendingBytes = 0
    locations.removeAll(keepingCapacity: true)
    guard let current = run else { return }
    run = nil
    await current.segments.invalidate()
    await current.demuxer.close()
  }

  /// Passes a segment over, or gives up after too many in a row.
  private func lose(_ index: Int, _ error: Error) throws {
    lostInARow += 1
    diagnostics?.record("hls_segment_lost", values: ["segment": Double(index), "lostInARow": Double(lostInARow)])
    guard lostInARow < Self.lostSegmentsTolerated else {
      throw UmbelError.sourceUnavailable(detail: "segments cannot be had: \(UmbelError.detail(for: error))")
    }
    nextIndex = index + 1
    continuing = false
  }

  /// Reads on to the first video keyframe, holding everything read for the
  /// caller.
  private func firstVideoKeyframe() async throws -> DemuxPacket? {
    let video = Set(tracks.filter { $0.kind == .video }.map(\.id))
    guard !video.isEmpty else { return nil }
    var read: [DemuxPacket] = []
    defer { held = read + held }
    while read.count < 1_000, let packet = try await nextPacket() {
      read.append(packet)
      if video.contains(packet.trackID), packet.isKeyframe { return packet }
    }
    return nil
  }

  private func releasePending(in run: PlaylistRun) {
    held.append(contentsOf: pending.map { packet(from: $0, run: run) })
    pending.removeAll(keepingCapacity: true)
    pendingBytes = 0
  }

  private func packet(from located: PlaylistPacket, run: PlaylistRun) -> DemuxPacket {
    let raw = located.raw
    let trackID = located.trackID
    let duration = TrackMapping.time(ticks: raw.duration, num: raw.timeBaseNum, den: raw.timeBaseDen)
    let sourcePTS = TrackMapping.time(ticks: raw.pts, num: raw.timeBaseNum, den: raw.timeBaseDen)
    let sourceDTS = TrackMapping.time(ticks: raw.dts, num: raw.timeBaseNum, den: raw.timeBaseDen)
    let placed = timeline.place(
      presentation: sourcePTS, decode: sourceDTS,
      duration: duration, segment: located.segment?.index)
    diagnostics?.record("demux_packet", values: [
      "track": Double(trackID.rawValue), "stream": Double(raw.streamIndex),
      "run": Double(run.number), "startSegment": Double(run.startSegment),
      "segment": located.segment.map { Double($0.index) } ?? .nan,
      "segmentStart": located.segment?.start ?? .nan,
      "bytePosition": raw.bytePosition.map(Double.init) ?? .nan,
      "sourcePTS": sourcePTS.seconds, "sourceDTS": sourceDTS.seconds,
      "mappedPTS": placed.presentation.seconds, "mappedDTS": placed.decode.seconds,
      "duration": duration.seconds, "timeBaseNum": Double(raw.timeBaseNum), "timeBaseDen": Double(raw.timeBaseDen)],
      labels: ["path": "playlist", "sourcePTSTicks": String(raw.pts), "sourceDTSTicks": String(raw.dts)])
    var packet = DemuxPacket(
      trackID: trackID, data: raw.data,
      presentationTime: placed.presentation, decodeTime: placed.decode,
      duration: duration, isKeyframe: raw.isKeyframe)
    packet.decoderParameters = parameters[trackID]
    return packet
  }

  private static func callbacks(for segments: HLSSegmentStream) -> FFmpegIOCallbacks {
    let cursor = StreamingCursor(source: segments)
    return FFmpegIOCallbacks(
      read: { try await cursor.read(maxLength: $0) },
      seek: { try await cursor.seek(toOffset: $0) },
      totalLength: { nil },
      canSeek: false)
  }
}
