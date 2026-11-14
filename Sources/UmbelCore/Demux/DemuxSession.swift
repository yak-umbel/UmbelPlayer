import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// A demux session: opens a source, lists its tracks, hands out packets in
/// order, and seeks.
///
/// Live and on-demand content share it. They part only in the cursor built
/// (random access or sequential); reading packets, mapping tracks and
/// telling the end are the same from there.
public actor DemuxSession {
  private let source: UmbelSource
  private let cursor: any ByteCursor
  private let configuration: DemuxConfiguration
  private let sourceName: String
  private let diagnostics: UmbelPlaybackDiagnostics?

  private var demuxer: FFmpegDemuxer?
  /// Set when the source is a playlist; everything below goes to it then.
  private var playlist: PlaylistDemuxer?
  private var loadedTracks: [UmbelTrack] = []
  private var loadedDuration: CMTime = .indefinite
  /// Where the file's own timestamps start. Everything leaving this session
  /// is moved back by it, so the timeline starts at zero; see `open()`.
  private var timelineOrigin: CMTime = .zero

  public init(
    source: UmbelSource, configuration: DemuxConfiguration = .init(),
    diagnostics: UmbelPlaybackDiagnostics?
  ) {
    self.source = source
    self.configuration = configuration
    self.sourceName = String(describing: type(of: source))
    self.diagnostics = diagnostics
    // The one place they part: a random-access source keeps a position, a
    // streaming one its own cursor.
    if let randomAccess = source as? any UmbelRandomAccessSource {
      self.cursor = RandomAccessCursor(source: randomAccess)
    } else if let streaming = source as? any UmbelStreamingSource {
      self.cursor = StreamingCursor(source: streaming)
    } else {
      // A source that implements only the base protocol has nothing to
      // read: an empty stream that ends at once.
      self.cursor = StreamingCursor(source: EmptyStreamingSource())
    }
  }

  public init(source: UmbelSource, configuration: DemuxConfiguration = .init()) {
    self.init(source: source, configuration: configuration, diagnostics: nil)
  }

  public var tracks: [UmbelTrack] { loadedTracks }
  public var duration: CMTime { loadedDuration }
  /// True when the source can seek. A playlist FFmpeg reads is seekable when
  /// it has a duration: a live one has none.
  public var isSeekable: Bool {
    if let playlist { return !playlist.isLive }
    if readsByAddress { return loadedDuration.isNumeric }
    return cursor.canSeek
  }
  /// Reading a playlist through FFmpeg, by its address.
  private var readsByAddress = false

  public func open() async throws {
    guard demuxer == nil, playlist == nil else { return }
    // Enough to tell a playlist by, and kept: reading goes on from there.
    let head = try await (source as? any UmbelRandomAccessSource)?.read(offset: 0, maxLength: 64) ?? Data()
    switch try await HLSPlaylistLoader.load(from: source, head: head) {
    case .playlist(let found, let address, let open)?:
      do {
        try await openPlaylist(found, open: open)
        diagnostics?.record("demux_open", labels: ["path": "playlist"])
      } catch {
        // Not a transport stream after all — raw audio segments, say.
        readsByAddress = true
        try await adopt(FFmpegDemuxer(
          address: address.absoluteString, opener: PlaylistResourceOpener.make(open), configuration: playlistReading))
        diagnostics?.record("demux_open", values: ["timelineOrigin": timelineOrigin.seconds],
                            labels: ["path": "hlsFallback", "reason": "playlistOpenFailed"])
      }
      return
    case .ffmpeg(let address, let open)?:
      readsByAddress = true
      try await adopt(FFmpegDemuxer(
        address: address.absoluteString, opener: PlaylistResourceOpener.make(open), configuration: playlistReading))
      diagnostics?.record("demux_open", values: ["timelineOrigin": timelineOrigin.seconds],
                          labels: ["path": "hlsFallback", "reason": "playlistLayout"])
      return
    case nil:
      await (cursor as? RandomAccessCursor)?.hold(head)
    }

    let cursor = self.cursor
    let callbacks = FFmpegIOCallbacks(
      read: { maxLength in try await cursor.read(maxLength: maxLength) },
      seek: { offset in try await cursor.seek(toOffset: offset) },
      totalLength: { await cursor.totalLength },
      canSeek: cursor.canSeek
    )
    try await adopt(FFmpegDemuxer(
      callbacks: callbacks,
      configuration: FFmpegDemuxerConfiguration(
        ioBufferSize: configuration.ioBufferSize,
        probeSize: configuration.probeSize,
        analyzeDurationMicroseconds: Int64(configuration.analyzeDuration * 1_000_000)
      )
    ))
    diagnostics?.record("demux_open", values: ["timelineOrigin": timelineOrigin.seconds],
                        labels: ["path": "container"])
  }

  /// FFmpeg's own playlist reading, the fallback: segment names are taken
  /// whatever their extension, since every address goes through the
  /// source's opener, which lets through only what it should.
  private var playlistReading: FFmpegDemuxerConfiguration {
    FFmpegDemuxerConfiguration(
      ioBufferSize: configuration.ioBufferSize, probeSize: configuration.probeSize,
      analyzeDurationMicroseconds: Int64(configuration.analyzeDuration * 1_000_000),
      formatName: "hls", formatOptions: ["allowed_extensions": "ALL", "extension_picky": "0"])
  }

  /// Opens a demuxer and takes its tracks, duration and start.
  private func adopt(_ demuxer: FFmpegDemuxer) async throws {
    do {
      try await demuxer.open()
    } catch {
      await demuxer.close()
      throw Self.translate(error, sourceName: sourceName)
    }

    let streams = await demuxer.streams()
    self.loadedTracks = streams.compactMap(TrackMapping.track(from:))

    if let microseconds = await demuxer.durationTicks() {
      self.loadedDuration = CMTime(value: microseconds, timescale: 1_000_000)
    } else {
      self.loadedDuration = .indefinite
    }

    // Move timestamps back by the file's start so the timeline starts at zero.
    if !configuration.preservesSourceTimestamps,
       let microseconds = await demuxer.startTicks() {
      self.timelineOrigin = CMTime(value: microseconds, timescale: 1_000_000)
    }

    self.demuxer = demuxer
  }

  public func nextPacket() async throws -> DemuxPacket? {
    if let playlist {
      do {
        return try await playlist.nextPacket()
      } catch {
        throw Self.translate(error, sourceName: sourceName)
      }
    }
    guard let demuxer else { throw UmbelError.interrupted }
    do {
      guard let packet = try await demuxer.readPacket() else { return nil }
      let sourcePTS = TrackMapping.time(ticks: packet.pts, num: packet.timeBaseNum, den: packet.timeBaseDen)
      let sourceDTS = TrackMapping.time(ticks: packet.dts, num: packet.timeBaseNum, den: packet.timeBaseDen)
      let mapped = DemuxPacket(
        trackID: UmbelTrack.ID(rawValue: packet.streamIndex),
        data: packet.data,
        presentationTime: onTimeline(sourcePTS),
        decodeTime: onTimeline(sourceDTS),
        duration: TrackMapping.time(
          ticks: packet.duration, num: packet.timeBaseNum, den: packet.timeBaseDen),
        isKeyframe: packet.isKeyframe
      )
      diagnostics?.record("demux_packet", values: [
        "track": Double(packet.streamIndex), "sourcePTS": sourcePTS.seconds, "sourceDTS": sourceDTS.seconds,
        "mappedPTS": mapped.presentationTime.seconds, "mappedDTS": mapped.decodeTime.seconds,
        "duration": mapped.duration.seconds, "timelineOrigin": timelineOrigin.seconds,
        "timeBaseNum": Double(packet.timeBaseNum), "timeBaseDen": Double(packet.timeBaseDen)],
        labels: ["path": readsByAddress ? "hlsFallback" : "container",
                 "sourcePTSTicks": String(packet.pts), "sourceDTSTicks": String(packet.dts)])
      return mapped
    } catch {
      throw Self.translate(error, sourceName: sourceName)
    }
  }

  public func seek(to time: CMTime) async throws {
    diagnostics?.record("demux_seek", values: ["target": time.seconds])
    if let playlist {
      guard time.isValid, !time.isIndefinite else { throw UmbelError.seekUnsupported }
      do {
        try await playlist.seek(to: time)
      } catch {
        throw Self.translate(error, sourceName: sourceName)
      }
      return
    }
    guard cursor.canSeek else { throw UmbelError.seekUnsupported }
    guard let demuxer else { throw UmbelError.interrupted }
    guard time.isValid, !time.isIndefinite else { throw UmbelError.seekUnsupported }
    do {
      try await demuxer.seek(toSeconds: (time + timelineOrigin).seconds)
    } catch {
      throw Self.translate(error, sourceName: sourceName)
    }
  }

  /// Makes an audio decoder for a track. Internal because it returns the type
  /// beneath: codec parameters come from the container.
  internal func makeAudioDecoder(for trackID: UmbelTrack.ID) async throws -> FFmpegAudioDecoder {
    do {
      let decoder: FFmpegAudioDecoder
      if let playlist {
        decoder = try await playlist.makeAudioDecoder(for: trackID)
      } else {
        guard let demuxer else { throw UmbelError.interrupted }
        decoder = try await demuxer.makeAudioDecoder(streamIndex: trackID.rawValue)
      }
      if let track = loadedTracks.first(where: { $0.id == trackID }) {
        let format = AudioOutputFormat.for(track)
        decoder.convertOutput(
          toSampleRate: Int32(format.sampleRate), channelCount: Int32(format.channelCount))
      }
      return decoder
    } catch let error as FFmpegDecoderError {
      switch error {
      case .decoderNotFound(let name):
        throw UmbelError.unsupportedCodec(name)
      case .notAnAudioStream:
        throw UmbelError.unsupportedCodec("not an audio track")
      default:
        throw UmbelError.decoderFailure(codec: "audio", code: 0)
      }
    }
  }

  /// Makes a video decoder for a track. Internal for the same reason as audio.
  internal func makeVideoDecoder(
    for trackID: UmbelTrack.ID,
    preferHardware: Bool = true,
    softwareThreadCount: Int32 = 0
  ) async throws -> FFmpegVideoDecoder {
    do {
      if let playlist {
        return try await playlist.makeVideoDecoder(
          for: trackID, preferHardware: preferHardware, softwareThreadCount: softwareThreadCount)
      }
      guard let demuxer else { throw UmbelError.interrupted }
      return try await demuxer.makeVideoDecoder(
        streamIndex: trackID.rawValue, preferHardware: preferHardware,
        softwareThreadCount: softwareThreadCount)
    } catch let error as FFmpegDecoderError {
      switch error {
      case .decoderNotFound(let name):
        throw UmbelError.unsupportedCodec(name)
      case .notAVideoStream:
        throw UmbelError.unsupportedCodec("not a video track")
      default:
        throw UmbelError.decoderFailure(codec: "video", code: 0)
      }
    }
  }

  /// A copy of a track's codec parameters, which a decoder can be made from.
  internal func codecParameters(for trackID: UmbelTrack.ID) async -> FFmpegCodecParameters? {
    if let playlist { return await playlist.codecParameters(for: trackID) }
    return await demuxer?.codecParameters(streamIndex: trackID.rawValue)
  }

  /// The latest indexed position of a track at or before `time`; nil when
  /// the container does not index that track there.
  internal func indexedTime(of trackID: UmbelTrack.ID, atOrBefore time: CMTime) async -> CMTime? {
    guard playlist == nil, let demuxer, time.isValid else { return nil }
    let seconds = await demuxer.latestIndexedTime(
      streamIndex: trackID.rawValue, atOrBefore: (time + timelineOrigin).seconds)
    return seconds.map { onTimeline(CMTime(seconds: $0, preferredTimescale: 1_000_000)) }
  }

  /// A time of the file's, moved onto the timeline. Missing times stay
  /// missing.
  private func onTimeline(_ time: CMTime) -> CMTime {
    time.isValid ? time - timelineOrigin : time
  }

  /// Files attached to the container, fonts among them.
  internal func attachments() async -> [FFmpegAttachment] {
    guard playlist == nil else { return [] }
    return await demuxer?.attachments() ?? []
  }

  /// Creates a text subtitle decoder for a track. Internal for the same
  /// reason as the others: it returns the underlying type.
  internal func makeSubtitleDecoder(for trackID: UmbelTrack.ID) async throws -> FFmpegSubtitleDecoder {
    do {
      if let playlist { return try await playlist.makeSubtitleDecoder(for: trackID) }
      guard let demuxer else { throw UmbelError.interrupted }
      return try await demuxer.makeSubtitleDecoder(streamIndex: trackID.rawValue)
    } catch let error as FFmpegDecoderError {
      switch error {
      case .decoderNotFound(let name):
        throw UmbelError.unsupportedCodec(name)
      case .notASubtitleStream:
        throw UmbelError.trackUnavailable("track \(trackID.rawValue) is not a subtitle track")
      default:
        throw UmbelError.decoderFailure(codec: "subtitle", code: 0)
      }
    }
  }

  /// Gives up the read the container is being read in, if the source is
  /// blocked in one: it is asked to stop through cancellation, and the
  /// packet being read fails. The source stays open, and reads again from
  /// wherever the next seek puts the demuxer; until `resumeReading()`,
  /// reads that begin are given up as they do.
  ///
  /// For whoever is about to stop reading and then seek or close — a
  /// reader's stop would otherwise wait for the source to answer. A playlist
  /// is the same, its segments being what the source is asked for.
  public func abandonReading() {
    demuxer?.abandonRead()
    playlist?.abandonReading()
  }

  /// Reads go on as usual again, after `abandonReading()`.
  public func resumeReading() {
    demuxer?.resumeReads()
    playlist?.resumeReading()
  }

  /// Closes the session. Can be called again.
  ///
  /// Only what the session holds is released. **Not the source**: whoever
  /// passed it in holds it and decides how long it lives; the same source
  /// may feed another session next.
  public func close() async {
    if let playlist {
      self.playlist = nil
      await playlist.close()
      return
    }
    guard let demuxer else { return }
    self.demuxer = nil
    await demuxer.close()
  }

  /// A playlist: runs of segments, each demuxed as the format its segments
  /// are in.
  private func openPlaylist(
    _ found: any HLSSegmentSource, open: @escaping HLSPlaylistLoader.Opener
  ) async throws {
    let playlist = PlaylistDemuxer(
      playlist: found, open: open,
      configuration: FFmpegDemuxerConfiguration(
        ioBufferSize: configuration.ioBufferSize,
        probeSize: configuration.probeSize,
        // A segment says what it holds within its first frames; probing
        // each run for long would hold up each run's first packet. The
        // demuxer names each run's format from the playlist.
        analyzeDurationMicroseconds: min(Int64(configuration.analyzeDuration * 1_000_000), 1_000_000)),
      diagnostics: diagnostics)
    do {
      try await playlist.open()
    } catch {
      await playlist.close()
      throw Self.translate(error, sourceName: sourceName)
    }
    loadedTracks = await playlist.tracks
    loadedDuration = await playlist.duration
    self.playlist = playlist
  }

  private static func translate(_ error: Error, sourceName: String) -> Error {
    guard let demuxError = error as? FFmpegDemuxerError else { return error }
    switch demuxError {
    case .openFailed(let code):
      switch code {
      case .interrupted: return UmbelError.interrupted
      default: return UmbelError.unsupportedContainer(sourceName)
      }
    case .notOpened:
      return UmbelError.interrupted
    case .interrupted:
      return UmbelError.interrupted
    case .seekFailed:
      return UmbelError.seekUnsupported
    case .readFailed:
      return UmbelError.sourceUnavailable(detail: "reading a packet failed")
    }
  }
}

/// A source that implements only the base protocol has nothing to read: an
/// empty stream that ends at once.
private struct EmptyStreamingSource: UmbelStreamingSource {
  var contentLength: Int64? { get async { nil } }
  func readNext(maxLength: Int) async throws -> Data { Data() }
  func invalidate() async {}
}
