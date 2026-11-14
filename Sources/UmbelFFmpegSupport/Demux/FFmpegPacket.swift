import Foundation

/// A compressed packet, in FFmpeg's own shape.
///
/// Timestamps are integer ticks in the stream's time base, which comes with
/// them for the layer above to convert. A missing timestamp is
/// `noTimestamp`, not 0 — 0 is a valid first timestamp.
public struct FFmpegPacket: Sendable, Equatable {
  /// AV_NOPTS_VALUE
  public static let noTimestamp: Int64 = Int64.min

  public let streamIndex: Int32
  public let data: Data
  public let pts: Int64
  public let dts: Int64
  public let duration: Int64
  public let timeBaseNum: Int32
  public let timeBaseDen: Int32
  public let isKeyframe: Bool
  /// Position in the logical input stream, when the container supplies it.
  public let bytePosition: Int64?

  public init(
    streamIndex: Int32,
    data: Data,
    pts: Int64,
    dts: Int64,
    duration: Int64,
    timeBaseNum: Int32,
    timeBaseDen: Int32,
    isKeyframe: Bool
  ) {
    self.init(streamIndex: streamIndex, data: data, pts: pts, dts: dts,
      duration: duration, timeBaseNum: timeBaseNum, timeBaseDen: timeBaseDen,
      isKeyframe: isKeyframe, bytePosition: nil)
  }

  public init(
    streamIndex: Int32,
    data: Data,
    pts: Int64,
    dts: Int64,
    duration: Int64,
    timeBaseNum: Int32,
    timeBaseDen: Int32,
    isKeyframe: Bool,
    bytePosition: Int64?
  ) {
    self.streamIndex = streamIndex
    self.data = data
    self.pts = pts
    self.dts = dts
    self.duration = duration
    self.timeBaseNum = timeBaseNum
    self.timeBaseDen = timeBaseDen
    self.isKeyframe = isKeyframe
    self.bytePosition = bytePosition
  }
}
