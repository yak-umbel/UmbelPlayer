import Foundation

public struct FFmpegDemuxerConfiguration: Sendable {
  public var ioBufferSize: Int
  public var probeSize: Int64
  public var analyzeDurationMicroseconds: Int64
  /// The container format by FFmpeg's name for it; nil to probe for it.
  public var formatName: String?
  /// Options for the demuxer beneath, by FFmpeg's names for them.
  public var formatOptions: [String: String]

  public init(
    ioBufferSize: Int = 64 * 1024,
    probeSize: Int64 = 1024 * 1024,
    analyzeDurationMicroseconds: Int64 = 5_000_000,
    formatName: String? = nil,
    formatOptions: [String: String] = [:]
  ) {
    self.ioBufferSize = ioBufferSize
    self.probeSize = probeSize
    self.analyzeDurationMicroseconds = analyzeDurationMicroseconds
    self.formatName = formatName
    self.formatOptions = formatOptions
  }
}
