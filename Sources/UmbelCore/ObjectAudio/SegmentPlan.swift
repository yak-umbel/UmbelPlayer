import CoreMedia
import Foundation

/// Where a sound track's segments fall, and the playlist that lists them.
///
/// Segments are a whole number of frames, laid on the track's shifted time
/// (see `FragmentedAudioTrack.shift`), so the playlist can be written whole
/// before a packet is read: the system player asks for any segment by
/// number, and each is made when asked.
internal struct SegmentPlan: Equatable, Sendable {
  /// One compressed frame: 1536 samples for E-AC-3.
  let frameDuration: CMTime
  let framesPerSegment: Int
  /// The film's length.
  let duration: CMTime
  /// Added to the film's time for the track's; see `FragmentedAudioTrack`.
  let shift: CMTime

  var segmentDuration: CMTime { CMTimeMultiply(frameDuration, multiplier: Int32(framesPerSegment)) }

  /// The track's length, shifted, over whole segments.
  var count: Int {
    let total = (duration + shift).seconds
    return max(1, Int((total / segmentDuration.seconds).rounded(.up)))
  }

  /// Which frame of the track a packet presented at `time` is, by the
  /// nearest: containers keep times in milliseconds, which fall either side
  /// of a frame's own. Negative before the track's shifted start.
  func frame(of time: CMTime) -> Int {
    Int(((time + shift).seconds / frameDuration.seconds).rounded())
  }

  /// The segment holding a packet presented at `time`, by its nearest
  /// frame. Clamped to the segments there are.
  func index(of time: CMTime) -> Int {
    min(max(0, frame(of: time) / framesPerSegment), count - 1)
  }

  /// The first segment to read for a seek to `time`: the one before the
  /// segment holding it. The system player asks for that one too, and
  /// starting there without it, stands still while saying it plays. The
  /// holding segment is found a frame early, so that rounding on either
  /// side of a boundary cannot leave it unread.
  func firstSegment(forSeekTo time: CMTime) -> Int {
    let position = (time + shift - frameDuration).seconds / segmentDuration.seconds
    return max(0, min(Int(position.rounded(.down)), count - 1) - 1)
  }

  /// Where segment `index` starts, in the film's time.
  func start(of index: Int) -> CMTime {
    CMTimeSubtract(CMTimeMultiply(segmentDuration, multiplier: Int32(index)), shift)
  }

  /// How long segment `index` plays: a full segment, the last the rest.
  func length(of index: Int) -> CMTime {
    guard index == count - 1 else { return segmentDuration }
    return CMTimeSubtract(duration + shift, CMTimeMultiply(segmentDuration, multiplier: Int32(index)))
  }

  /// An on-demand playlist, whole from the start. Played from `start`, in
  /// the film's time, when given: the system player then asks first for the
  /// segments there.
  func playlist(initName: String, segmentName: (Int) -> String, start: CMTime? = nil) -> String {
    let lengths = (0..<count).map { length(of: $0).seconds }
    // Each length rounded to the nearest second may not exceed the target.
    let target = lengths.map { Int($0.rounded()) }.max() ?? 1
    var lines = [
      "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
      "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS",
    ]
    if let start, start.isNumeric {
      lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.6f,PRECISE=YES", max(0, (start + shift).seconds)))
    }
    lines.append("#EXT-X-MAP:URI=\"\(initName)\"")
    for (index, length) in lengths.enumerated() {
      lines.append(String(format: "#EXTINF:%.6f,", length))
      lines.append(segmentName(index))
    }
    lines.append("#EXT-X-ENDLIST")
    return lines.joined(separator: "\n") + "\n"
  }
}
