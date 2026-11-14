import Foundation

/// Reads an external subtitle file whole and decodes it into a complete
/// timeline.
///
/// Whole, because subtitle files are small: once every cue is in memory a
/// seek needs no second demuxer kept in step, and a long cue is never lost to
/// where reading restarted.
internal enum ExternalSubtitleLoader {
  /// Far beyond any real subtitle file; only there to stop a film passed by
  /// mistake from being read into memory.
  static let sizeLimit = 32 * 1024 * 1024

  static func load(
    _ source: any UmbelSource, id: UmbelTrack.ID, language: String?, title: String?
  ) async throws -> ExternalSubtitle {
    let raw = try await readAndClose(source)
    try Task.checkCancellation()
    let isSUP = ExternalSUPInspector.isSUP(raw)
    if isSUP { try ExternalSUPInspector.validate(raw) }
    let content: Data
    if isSUP {
      content = raw
    } else {
      guard let text = SubtitleEncoding.utf8(from: raw) else {
        throw UmbelError.unsupportedContainer("cannot tell the subtitle file's text encoding")
      }
      content = text
    }

    var configuration = DemuxConfiguration()
    configuration.preservesSourceTimestamps = isSUP
    let demux = DemuxSession(source: MemorySource(data: content), configuration: configuration)
    let decoded: (stream: UmbelTrack, timeline: SubtitleTimeline)
    do {
      decoded = try await decodeAll(demux, strictSUP: isSUP)
      await demux.close()
    } catch {
      await demux.close()
      throw error
    }
    let (stream, timeline) = decoded

    let track = UmbelTrack(
      id: id, kind: .subtitle, codecName: stream.codecName,
      language: language ?? stream.language, title: title ?? stream.title,
      isDefault: false, isForced: false, video: nil, audio: nil, isExternal: true)
    // ASS keeps its bytes: libass reads the whole script itself, [Fonts]
    // section included, which the demuxed packets would leave behind.
    let isASS = stream.codecName == "ass" || stream.codecName == "ssa"
    return ExternalSubtitle(track: track, timeline: timeline, assScript: isASS ? content : nil)
  }

  private static func decodeAll(
    _ demux: DemuxSession, strictSUP: Bool
  ) async throws -> (stream: UmbelTrack, timeline: SubtitleTimeline) {
    do {
      try Task.checkCancellation()
      try await demux.open()
    } catch {
      try Task.checkCancellation()
      throw UmbelError.unsupportedContainer("not a subtitle file that can be read")
    }
    guard let stream = await demux.tracks.first(where: { $0.kind == .subtitle }) else {
      throw UmbelError.unsupportedContainer("no subtitles in the file")
    }
    if strictSUP, stream.codecName != "hdmv_pgs_subtitle" {
      throw UmbelError.unsupportedContainer("SUP did not contain a PGS subtitle stream")
    }

    let session = SubtitleDecodeSession(
      decoder: try await demux.makeSubtitleDecoder(for: stream.id), retention: .complete)
    do {
      while let packet = try await demux.nextPacket() {
        try Task.checkCancellation()
        guard packet.trackID == stream.id else { continue }
        await session.receive(packet)
      }
      try Task.checkCancellation()
      let timeline = await session.timeline
      if strictSUP {
        let failures = await session.failedPacketCount
        guard failures == 0, timeline.count > 0 else {
          throw UmbelError.unsupportedContainer("SUP has no decodable picture timeline")
        }
      }
      await session.close()
      return (stream, timeline)
    } catch {
      await session.close()
      throw error
    }
  }

  private static func readAndClose(_ source: any UmbelSource) async throws -> Data {
    try await withTaskCancellationHandler(operation: {
      do {
        let raw = try await readAll(source)
        await source.invalidate()
        return raw
      } catch {
        await source.invalidate()
        throw error
      }
    }, onCancel: {
      Task { await source.invalidate() }
    })
  }

  /// Every byte, up to the limit. Both kinds of source work: a file or a
  /// ranged HTTP resource, or a plain stream read to its end.
  private static func readAll(_ source: any UmbelSource) async throws -> Data {
    let chunk = 256 * 1024
    var data = Data()
    if let length = await source.contentLength, length > sizeLimit {
      throw UmbelError.unsupportedContainer("subtitle file larger than 32 MiB")
    }
    while true {
      try Task.checkCancellation()
      let piece: Data
      if let randomAccess = source as? any UmbelRandomAccessSource {
        piece = try await randomAccess.read(offset: Int64(data.count), maxLength: chunk)
      } else if let streaming = source as? any UmbelStreamingSource {
        piece = try await streaming.readNext(maxLength: chunk)
      } else {
        piece = Data()
      }
      try Task.checkCancellation()
      if piece.isEmpty { return data }
      guard piece.count <= sizeLimit - data.count else {
        throw UmbelError.unsupportedContainer("subtitle file larger than 32 MiB")
      }
      data.append(piece)
    }
  }
}

/// An external subtitle file after loading.
internal struct ExternalSubtitle: Sendable {
  let track: UmbelTrack
  /// Every cue, for text uses and the CoreText path.
  let timeline: SubtitleTimeline
  /// The script as UTF-8, for libass. Nil unless the file is ASS or SSA.
  let assScript: Data?
}
