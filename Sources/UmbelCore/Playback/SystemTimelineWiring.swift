import Foundation

/// An audio output whose sound plays on the system's timeline.
internal protocol SystemTimelineKeeping: Sendable {
  var timeline: any SystemTimeline { get }
}

extension SampleBufferAudioOutput: SystemTimelineKeeping {}

/// How a session joins its clock and renderers to the system's timeline,
/// when its audio output keeps one. Kept apart from the session, which has
/// no lines to spare.
internal enum SystemTimelineWiring {
  /// On the output's timeline when it keeps one; otherwise as before, the
  /// clock worked out from anchors and the host clock.
  static func clock(
    hostTime: HostTimeSource, audioOutput: (any AudioOutput)?, videoRenderer: (any VideoRenderer)?,
    diagnostics: UmbelPlaybackDiagnostics? = nil
  ) -> PresentationClock {
    PresentationClock(
      hostTime: hostTime, follower: videoRenderer as? any ClockFollower,
      timeline: (audioOutput as? any SystemTimelineKeeping)?.timeline, diagnostics: diagnostics)
  }

  /// Puts the renderer's display layer on the output's timeline. Called
  /// last in loading, so a load that fails leaves nothing joined.
  static func join(_ audioOutput: (any AudioOutput)?, _ videoRenderer: (any VideoRenderer)?) async throws {
    guard let timeline = (audioOutput as? any SystemTimelineKeeping)?.timeline,
          let joining = videoRenderer as? any SystemTimelineJoining else { return }
    try await joining.join(timeline)
  }

  static func leave(_ videoRenderer: (any VideoRenderer)?) async {
    await (videoRenderer as? any SystemTimelineJoining)?.leave()
  }
}
