import Foundation

extension PlaybackSession {
  /// A session without diagnostics, as before they could be passed; see
  /// `init(source:audioOutput:videoRenderer:compositesSubtitles:hostTime:configuration:buffering:cachedAudio:videoDecodingMode:objectAudio:diagnostics:)`.
  public init(
    source: UmbelSource,
    audioOutput: (any AudioOutput)? = nil,
    videoRenderer: (any VideoRenderer)? = nil,
    compositesSubtitles: Bool = true,
    hostTime: HostTimeSource = SystemHostTimeSource(),
    configuration: DemuxConfiguration = .init(),
    buffering: BufferingConfiguration = .init(),
    cachedAudio: CachedAudioConfiguration = .init(),
    videoDecodingMode: UmbelVideoDecodingMode = .synchronous,
    objectAudio: UmbelObjectAudioMode = .automatic
  ) {
    self.init(
      source: source, audioOutput: audioOutput, videoRenderer: videoRenderer,
      compositesSubtitles: compositesSubtitles, hostTime: hostTime, configuration: configuration,
      buffering: buffering, cachedAudio: cachedAudio, videoDecodingMode: videoDecodingMode,
      objectAudio: objectAudio, diagnostics: nil)
  }
}

// The original diagnostics-aware constructor remains available.
extension PlaybackSession {
  public init(
    source: UmbelSource,
    audioOutput: (any AudioOutput)? = nil,
    videoRenderer: (any VideoRenderer)? = nil,
    compositesSubtitles: Bool = true,
    hostTime: HostTimeSource = SystemHostTimeSource(),
    configuration: DemuxConfiguration = .init(),
    buffering: BufferingConfiguration = .init(),
    cachedAudio: CachedAudioConfiguration = .init(),
    videoDecodingMode: UmbelVideoDecodingMode = .synchronous,
    objectAudio: UmbelObjectAudioMode = .automatic,
    diagnostics: UmbelPlaybackDiagnostics?
  ) {
    self.init(source: source, audioOutput: audioOutput, videoRenderer: videoRenderer, videoPolicy: nil,
      compositesSubtitles: compositesSubtitles, hostTime: hostTime, configuration: configuration,
      buffering: buffering, cachedAudio: cachedAudio, videoDecodingMode: videoDecodingMode,
      objectAudio: objectAudio, diagnostics: diagnostics)
  }
}

// The same, with the video decoder asked for. `videoDecoder` has no default
// here, so that a call without it keeps meaning the initializers above.
extension PlaybackSession {
  public init(
    source: UmbelSource,
    audioOutput: (any AudioOutput)? = nil,
    videoRenderer: (any VideoRenderer)? = nil,
    compositesSubtitles: Bool = true,
    hostTime: HostTimeSource = SystemHostTimeSource(),
    configuration: DemuxConfiguration = .init(),
    buffering: BufferingConfiguration = .init(),
    cachedAudio: CachedAudioConfiguration = .init(),
    videoDecodingMode: UmbelVideoDecodingMode = .synchronous,
    videoDecoder: UmbelVideoDecoderConfiguration,
    objectAudio: UmbelObjectAudioMode = .automatic,
    diagnostics: UmbelPlaybackDiagnostics? = nil
  ) {
    self.init(source: source, audioOutput: audioOutput, videoRenderer: videoRenderer, videoPolicy: nil,
      compositesSubtitles: compositesSubtitles, hostTime: hostTime, configuration: configuration,
      buffering: buffering, cachedAudio: cachedAudio, videoDecodingMode: videoDecodingMode,
      videoDecoder: videoDecoder, objectAudio: objectAudio, diagnostics: diagnostics)
  }
}
