import Foundation

/// One independently owned decoder receiving a selected subtitle stream.
internal struct SubtitleRoute: Sendable {
  let id: UmbelTrack.ID
  let receiver: any SubtitlePacketReceiver
}

/// The two chains packets are fed along; subtitles follow the leading one.
internal enum PacketChain: CaseIterable { case audio, video }

/// A snapshot of packet destinations, with the seek generation that owns it.
internal struct PacketRouting: Sendable {
  internal let audioID: UmbelTrack.ID?
  internal let audioSession: AudioDecodeSession?
  /// Sound played by the system player instead of decoded: its packets go
  /// there, still encoded. Set in place of `audioSession`.
  internal let objectAudio: ObjectAudioRoute?
  internal let videoID: UmbelTrack.ID?
  internal let videoSession: (any VideoFrameSource)?
  internal let subtitleRoutes: [SubtitleRoute]
  internal let generation: Int

  internal init(
    audioID: UmbelTrack.ID?, audioSession: AudioDecodeSession?, objectAudio: ObjectAudioRoute? = nil,
    videoID: UmbelTrack.ID?, videoSession: (any VideoFrameSource)?,
    subtitleID: UmbelTrack.ID? = nil, subtitleReceiver: (any SubtitlePacketReceiver)? = nil,
    generation: Int, subtitleRoutes: [SubtitleRoute] = []
  ) {
    self.audioID = audioID
    self.audioSession = audioSession
    self.objectAudio = objectAudio
    self.videoID = videoID
    self.videoSession = videoSession
    self.generation = generation
    if let subtitleID, let subtitleReceiver {
      self.subtitleRoutes = [SubtitleRoute(id: subtitleID, receiver: subtitleReceiver)] + subtitleRoutes
    } else {
      self.subtitleRoutes = subtitleRoutes
    }
  }

  /// Nowhere, before the session routes anything.
  internal static let unrouted = PacketRouting(
    audioID: nil, audioSession: nil, videoID: nil, videoSession: nil, generation: 0)

  internal var selectedTracks: Set<UmbelTrack.ID> {
    Set([audioID, videoID].compactMap { $0 }).union(subtitleRoutes.map(\.id))
  }

  /// Something plays the sound: decoded here, or by the system player.
  internal var hasSound: Bool { audioSession != nil || objectAudio != nil }

  /// The track the cache's level is measured by. The system player takes
  /// sound as fast as it asks for it, so the picture measures then.
  internal var measuredTrack: UmbelTrack.ID? {
    objectAudio == nil ? audioID ?? videoID : videoID ?? audioID
  }

  /// Whether that level holds playback back; see `PacketCache`.
  internal var levelGatesPlayback: Bool { objectAudio == nil || videoID != nil }

  /// Sound the system player takes at its own pace; see `PacketCache.isFull`.
  internal var soundTakenOnDemand: UmbelTrack.ID? { objectAudio == nil ? nil : audioID }

  /// The track `chain` feeds: none without an output for it, or with
  /// nowhere to send its packets.
  internal func track(for chain: PacketChain, hasAudioOutput: Bool, hasVideoRenderer: Bool) -> UmbelTrack.ID? {
    switch chain {
    case .audio: return !hasAudioOutput || (audioSession == nil && objectAudio == nil) ? nil : audioID
    case .video: return !hasVideoRenderer || videoSession == nil ? nil : videoID
    }
  }

  /// Whether `chain` goes where it goes in `other`, in the same seek
  /// generation: a feeder holding one that does not is stale.
  internal func feeds(_ chain: PacketChain, as other: PacketRouting) -> Bool {
    guard generation == other.generation else { return false }
    switch chain {
    case .audio:
      return audioID == other.audioID && audioSession === other.audioSession && objectAudio === other.objectAudio
    case .video: return videoID == other.videoID && videoSession === other.videoSession
    }
  }
}
