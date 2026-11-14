/// Which decoder turns a video's compressed pictures into pictures, where
/// the playback engine decodes them. Given when a session is made, and kept
/// for all of it: a decoder made again — after the app was in the
/// background, or for content encoded otherwise — is made as the first was.
/// To change it, make a new session.
///
/// Neither choice reaches pictures the system decodes (DV that the system
/// shows itself, or that it decodes into pictures for the engine to show):
/// they are not decoded here, and the engine has nothing to choose.
public struct UmbelVideoDecoderConfiguration: Sendable, Equatable {
  public enum Preference: String, Sendable {
    /// The hardware decoder where it can decode the video, software where it
    /// cannot. What has always been done.
    case hardware
    /// The software decoder, even for a video the hardware could decode. A
    /// preference, not a requirement: it changes nothing for what the system
    /// decodes.
    case software
  }

  /// The counts `softwareThreadCount` can take. Sixteen is as many as FFmpeg
  /// recommends, and as many as it picks itself when it chooses.
  public static let softwareThreadCounts = [1, 2, 4, 6, 8, 10, 12, 14, 16]

  public var preference: Preference

  /// Threads software decoding runs on; nil leaves the count to the decoder,
  /// which picks one more than the cores the device has, up to sixteen. A
  /// count that is not one of `softwareThreadCounts` is brought down to the
  /// one below it, the first when it is below them all. Ignored while the
  /// hardware decodes.
  ///
  /// H.264, HEVC, VP9 and most other codecs decode on threads by frame: each
  /// thread works on a frame of its own, so a count of *n* delays the first
  /// picture, and each one after a seek, by *n* − 1 frames, and holds *n*
  /// frames being decoded besides those waiting to be shown — about 25 MB each
  /// at 4K with 10 bits. Fewer threads answer sooner and hold less; more keep
  /// up with a video that fewer cannot. AV1 is decoded by a library that
  /// divides the work its own way, with a delay of the square root of the
  /// count, rounded up, in frames: four at sixteen threads.
  public var softwareThreadCount: Int? {
    didSet { softwareThreadCount = Self.limited(softwareThreadCount) }
  }

  public init(preference: Preference = .hardware, softwareThreadCount: Int? = nil) {
    self.preference = preference
    self.softwareThreadCount = Self.limited(softwareThreadCount)
  }

  private static func limited(_ count: Int?) -> Int? {
    guard let count else { return nil }
    return softwareThreadCounts.last { $0 <= count } ?? softwareThreadCounts[0]
  }

  internal var prefersHardware: Bool { preference == .hardware }

  /// As the decoder takes it: 0, the decoder's pick.
  internal var requestedThreads: Int32 { Int32(softwareThreadCount ?? 0) }
}

/// What decodes the chosen video track now; see
/// `PlaybackSession.videoDecoderStatus`.
public enum UmbelVideoDecoderStatus: Sendable, Equatable {
  /// Before successful loading, after stopping, or without a video output.
  case inactive
  /// The hardware decodes the pictures.
  case hardware
  /// The software decoder does, whether it was preferred or the hardware
  /// could not decode this video. `threads` is the count it runs on; nil
  /// where the decoder picks it and does not say (AV1, asked for no count).
  case software(threads: Int?)
  /// The system decodes the pictures, and the engine does not.
  case systemManaged
}
