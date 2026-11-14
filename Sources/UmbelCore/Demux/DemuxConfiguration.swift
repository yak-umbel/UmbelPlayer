import Foundation

/// What a demux session can be tuned with.
///
/// The defaults suit common containers; a starting point, not a verdict, to
/// be reviewed against real content.
public struct DemuxConfiguration: Sendable {
  /// The buffer size handed to the custom I/O beneath.
  public var ioBufferSize: Int
  /// The most bytes read while probing the container. On a source that
  /// cannot seek, probing cannot go back beyond this buffer.
  public var probeSize: Int64
  /// The longest stretch of content probed.
  public var analyzeDuration: TimeInterval
  /// Sidecar subtitles use their authored timestamps relative to the picture.
  internal var preservesSourceTimestamps = false

  public init(
    ioBufferSize: Int = 64 * 1024,
    probeSize: Int64 = 1024 * 1024,
    analyzeDuration: TimeInterval = 5
  ) {
    self.ioBufferSize = ioBufferSize
    self.probeSize = probeSize
    self.analyzeDuration = analyzeDuration
  }
}
