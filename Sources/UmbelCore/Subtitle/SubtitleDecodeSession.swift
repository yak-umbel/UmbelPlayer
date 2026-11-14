import CoreGraphics
import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Decodes the selected embedded subtitle track onto a timeline.
///
/// Packets arrive from the feed loop as playback reaches them; cues wait on the
/// timeline until the clock does. A bad packet is counted and skipped — one
/// broken subtitle must not stop the film.
internal actor SubtitleDecodeSession: SubtitlePacketReceiver {
  private let decoder: FFmpegSubtitleDecoder
  private let styles: ASSStyleSheet
  /// For an ASS track: libass gets every packet too, and draws the picture.
  /// The cues decoded here still serve text-only uses.
  internal let assSource: ASSSubtitleSource?
  /// Bitmap displays can reference palette/object definitions from earlier
  /// packets even after those packets' own display intervals have ended.
  internal let requiresCompleteHistory: Bool
  /// Where bitmap subtitles are placed when the stream does not say.
  private let fallbackCanvas: CGSize?
  private(set) var timeline: SubtitleTimeline
  private var isClosed = false
  private(set) var failedPacketCount = 0

  /// `.complete` when decoding a whole external file up front; `.window`
  /// for an embedded track decoded as playback reaches it. `fallbackCanvas`
  /// is the video's size, for bitmap streams that do not state their own.
  internal init(
    decoder: FFmpegSubtitleDecoder,
    retention: SubtitleTimeline.Retention = .window,
    assSource: ASSSubtitleSource? = nil,
    fallbackCanvas: CGSize? = nil
  ) {
    self.decoder = decoder
    self.requiresCompleteHistory = decoder.isBitmap
    self.styles = ASSStyleSheet(header: decoder.subtitleHeader)
    self.timeline = SubtitleTimeline(retention: retention)
    self.assSource = assSource
    self.fallbackCanvas = fallbackCanvas
  }

  internal func receive(_ packet: DemuxPacket) async {
    guard !isClosed else { return }
    let raw = FFmpegPacket(
      streamIndex: packet.trackID.rawValue,
      data: packet.data,
      pts: Self.microseconds(packet.presentationTime),
      dts: Self.microseconds(packet.decodeTime),
      duration: packet.duration.isValid ? Int64(packet.duration.seconds * 1_000_000) : 0,
      timeBaseNum: 1,
      timeBaseDen: 1_000_000,
      isKeyframe: packet.isKeyframe)
    do {
      for subtitle in try decoder.decode(raw) {
        insert(subtitle)
      }
    } catch {
      failedPacketCount += 1
    }
    // Finish native decoding before yielding, so a seek/close cannot invalidate it mid-packet.
    await assSource?.feed(packet)
  }

  /// Cues showing at `time`. Pruning happens here, on the way past, so the
  /// timeline stays as long as the stretch around the playhead.
  internal func cues(at time: CMTime) -> [UmbelSubtitleCue] {
    timeline.prune(before: time)
    return timeline.cues(at: time)
  }

  /// A seek: the stream restarts elsewhere and what was decoded no longer
  /// belongs to it.
  internal func flush() {
    guard !isClosed else { return }
    decoder.flush()
    timeline.removeAll()
  }

  internal func close() {
    guard !isClosed else { return }
    isClosed = true
    decoder.close()
    timeline.removeAll()
  }

  private func insert(_ subtitle: FFmpegSubtitle) {
    let start = CMTime(value: subtitle.startMicroseconds, timescale: 1_000_000)
    let end = subtitle.endMicroseconds.map { CMTime(value: $0, timescale: 1_000_000) }
    if decoder.isBitmap {
      // Each bitmap event replaces the whole picture: it ends whatever shows,
      // whatever that one's own end said. PGS clears the screen with an event
      // holding nothing; a DVB page's end is only a timeout, valid "should it
      // not have been redefined before that".
      timeline.cut(at: start)
      for cue in BitmapSubtitle.cues(
        from: subtitle, start: start, end: end, fallbackCanvas: fallbackCanvas) {
        timeline.insert(cue)
      }
      return
    }
    for line in subtitle.assLines {
      let cue = ASSDialogue.cue(from: line, styles: styles, start: start, end: end)
      // A line that is all tags or drawing commands has nothing to show.
      guard !cue.runs.isEmpty else { continue }
      timeline.insert(cue)
    }
  }

  private static func microseconds(_ time: CMTime) -> Int64 {
    guard time.isValid, !time.isIndefinite else { return FFmpegPacket.noTimestamp }
    return Int64((time.seconds * 1_000_000).rounded())
  }
}
