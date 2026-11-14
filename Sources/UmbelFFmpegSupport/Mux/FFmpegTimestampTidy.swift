import Foundation

/// Makes the timestamps of packets what a container will take, stream by
/// stream, in the time base they are about to be written in.
///
/// A packet with no time at all cannot be written, and is left out: a stream's
/// first packets often have none. One time stands in for the other. A decoding
/// time that does not come after the last of its stream is put just after it,
/// its presentation time moved the same, since a sender's timing is adjusted
/// again once its reports arrive, and can step back. A presentation time is
/// never before its decoding time.
struct FFmpegTimestampTidy {
  /// FFmpeg's "no timestamp" (AV_NOPTS_VALUE), which Swift does not import.
  static let noTimestamp = Int64.min

  private var last: [Int64]

  init(streams: Int) {
    last = [Int64](repeating: Self.noTimestamp, count: streams)
  }

  /// The times to write, or nil to leave the packet out.
  mutating func tidy(stream: Int, dts: Int64, pts: Int64) -> (dts: Int64, pts: Int64)? {
    var decode = dts == Self.noTimestamp ? pts : dts
    var present = pts == Self.noTimestamp ? dts : pts
    guard decode != Self.noTimestamp, stream >= 0, stream < last.count else { return nil }
    if last[stream] != Self.noTimestamp, decode <= last[stream] {
      let shift = last[stream] + 1 - decode
      decode += shift
      present += shift
    }
    present = max(present, decode)
    last[stream] = decode
    return (decode, present)
  }
}
