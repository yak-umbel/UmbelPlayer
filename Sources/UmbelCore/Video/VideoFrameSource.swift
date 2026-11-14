import Foundation

/// Where a video track's packets become frames: decoded here, or packaged
/// for the system to decode and show. What the playback pipeline, catching
/// up and the session ask of either.
internal protocol VideoFrameSource: Actor {
  /// `hidden`: the frame will not be shown — it comes before a seek's target.
  func decode(_ packet: DemuxPacket, hidden: Bool) async throws -> [VideoFrame]
  /// The frames still held, at the end of the content.
  func drain() async throws -> [VideoFrame]
  /// After a seek: nothing from before goes on.
  func flush() async
  /// Made anew for going on, as after the host was in the background.
  func renew() async throws
  func close() async
  /// Leaves frames no other frame refers to undecoded; see `VideoCatchUp`.
  func setSkipsNonReference(_ skips: Bool) async
  var skipsNonReference: Bool { get }
  /// What decoding here has done since the track was chosen; nil where the
  /// system decodes.
  var decodingCounts: UmbelDecodingCounts? { get async }
  /// What decodes the pictures here now; nil where the system decodes them.
  var decoderStatus: UmbelVideoDecoderStatus? { get async }
}

extension VideoFrameSource {
  var decodingCounts: UmbelDecodingCounts? { get async { nil } }
  var decoderStatus: UmbelVideoDecoderStatus? { get async { nil } }
}

extension VideoDecodeSession: VideoFrameSource {}

extension AsyncVideoDecodeSession: VideoFrameSource {}
