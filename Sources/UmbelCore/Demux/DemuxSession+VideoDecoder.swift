import UmbelFFmpegSupport

extension DemuxSession {
  /// A video decoder made as a session was asked to make its decoders.
  internal func makeVideoDecoder(
    for trackID: UmbelTrack.ID, configuration: UmbelVideoDecoderConfiguration
  ) async throws -> FFmpegVideoDecoder {
    try await makeVideoDecoder(
      for: trackID, preferHardware: configuration.prefersHardware,
      softwareThreadCount: configuration.requestedThreads)
  }
}
