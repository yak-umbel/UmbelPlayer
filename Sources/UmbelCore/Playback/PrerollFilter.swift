import CoreMedia
import Foundation

/// Sits between the demuxer and the cache after a seek, while reading still
/// runs ahead of the target.
///
/// Reading may start well before the target — up to ten seconds, so that a
/// subtitle already on screen at the target gets read. That must not cost
/// decoding or distort the buffer level:
///
/// - **Video**: only the group of pictures holding the target is passed on.
///   Each key frame before the target replaces what was held; the first packet
///   at or past the target releases it, or drops it if that packet is itself
///   a key frame. Decoding therefore does the same work as an ordinary seek.
/// - **Audio**: packets ending well before the target are dropped here, before
///   the cache counts them. Counted, they would open the buffering gate early
///   and let it starve straight after — two buffering reports for one seek.
///   A tenth of a second is kept for decoders that need warming up.
/// - **Everything else**, subtitles included, passes.
internal struct PrerollFilter {
  /// Audio kept before the target for decoder warm-up; Opus asks for 80 ms.
  static let audioWarmUp = 0.1

  private let target: Double
  private let audioTarget: Double
  private let video: UmbelTrack.ID?
  private let audio: UmbelTrack.ID?
  private var heldVideo: [DemuxPacket] = []
  private var videoReached: Bool
  private var audioReached: Bool

  /// `audioTarget`, when given, is where sound is kept from instead: the
  /// system player wants its segments whole, from before the target.
  init(target: CMTime, audioTarget: CMTime? = nil, video: UmbelTrack.ID?, audio: UmbelTrack.ID?) {
    self.target = target.seconds
    self.audioTarget = (audioTarget ?? target).seconds
    self.video = video
    self.audio = audio
    videoReached = video == nil
    audioReached = audio == nil
  }

  /// Both chains have reached the target; from here on the filter changes
  /// nothing and can be dropped.
  var isFinished: Bool { videoReached && audioReached }

  /// What to hand on for `packet`, in order. Often nothing, sometimes a
  /// whole held group at once.
  mutating func admit(_ packet: DemuxPacket) -> [DemuxPacket] {
    if packet.trackID == video { return admitVideo(packet) }
    if packet.trackID == audio { return admitAudio(packet) ? [packet] : [] }
    return [packet]
  }

  /// Content ended before reaching the target: hand over what is held so the
  /// last picture can still show.
  mutating func drain() -> [DemuxPacket] {
    defer { heldVideo.removeAll() }
    return heldVideo
  }

  private mutating func admitVideo(_ packet: DemuxPacket) -> [DemuxPacket] {
    guard !videoReached else { return [packet] }
    // Without a time the packet cannot be placed; pass it and stop filtering
    // rather than risk holding the stream back for good.
    guard let time = Self.seconds(packet.presentationTime) ?? Self.seconds(packet.decodeTime) else {
      videoReached = true
      return drain() + [packet]
    }
    if time >= target {
      videoReached = true
      let held = drain()
      return packet.isKeyframe ? [packet] : held + [packet]
    }
    if packet.isKeyframe {
      heldVideo = [packet]
    } else if !heldVideo.isEmpty {
      heldVideo.append(packet)
    }
    // Before any key frame: nothing could decode it anyway.
    return []
  }

  private mutating func admitAudio(_ packet: DemuxPacket) -> Bool {
    guard !audioReached, let start = Self.seconds(packet.presentationTime) else { return true }
    let duration = Self.seconds(packet.duration) ?? 0
    if start + duration >= audioTarget { audioReached = true }
    return start + duration > audioTarget - Self.audioWarmUp
  }

  private static func seconds(_ time: CMTime) -> Double? {
    guard time.isValid, !time.isIndefinite else { return nil }
    return time.seconds
  }
}
