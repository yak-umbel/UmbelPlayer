import Foundation

/// How much content to read ahead and optionally retain for backward seeks.
///
/// Playback starts, and starts again after a seek, with a second buffered,
/// and resumes after running dry with two: waiting long enough to start
/// smoothly, short enough not to be noticed. The target is ten seconds of
/// cache.
///
/// The earlier two and five seconds, on a link limited to just above the
/// bitrate, started a second later and held each stall for four seconds.
public struct BufferingConfiguration: Sendable {
    /// Enough buffered to start, and to start again after a seek.
    public var startThreshold: TimeInterval
    /// Enough buffered to resume after running dry. Higher than the start
    /// threshold: a link that could not keep up once will not straight away,
    /// and resuming at the start threshold makes playback stutter in short
    /// bursts. Capped by `target`, which is as much as the cache will ever
    /// hold.
    public var resumeThreshold: TimeInterval
    /// Below this the session reports buffering. It is the last warning before
    /// the output runs dry, not the moment it already has — reporting on an
    /// empty output would tell the host what it can already hear. Below the
    /// start threshold, so that starting and stalling are apart.
    public var lowWatermark: TimeInterval
    /// Stop reading once this much is buffered.
    public var target: TimeInterval
    /// Compressed payload bytes queued ahead of all decoders. Nil keeps only
    /// the duration limit. Values below one are treated as one byte.
    /// Reading stops after the packet that reaches this high-water mark;
    /// an indivisible packet may exceed it. A cached backward seek can also
    /// transfer history into this queue above the high-water mark without
    /// allocating new payload; reading waits for it to drain. Decoded output,
    /// subtitle history,
    /// retained audio, and demuxer preroll are separate stores. Audio and
    /// video packets of tracks not selected are dropped first; switching to
    /// such an audio track reads again from the current position when the
    /// source can seek. If subtitles alone exhaust the budget before media
    /// can be read, those cues may be discarded. Selected audio and video
    /// packets are preserved.
    public var maximumPacketBytes: Int?

    /// Compressed payload bytes retained for backward seeks, shared by media
    /// tracks. Zero (the default) or negative disables retention. Oldest data
    /// is evicted first; video history begins at a keyframe. A packet larger
    /// than the budget is not retained. Missing packets, decode dependencies,
    /// or subtitle history use normal seek instead. No fixed time span is
    /// promised. This bounds payload only, not metadata or total player memory.
    /// Separate from read-ahead, decoded output, subtitle history and cached
    /// audio extraction. Applies to seekable content with engine-decoded sound.
    public var maximumBackwardPacketBytes: Int = 0

    public init(
        startThreshold: TimeInterval = 1,
        resumeThreshold: TimeInterval = 2,
        lowWatermark: TimeInterval = 0.5,
        target: TimeInterval = 10,
        maximumPacketBytes: Int? = nil
    ) {
        self.startThreshold = startThreshold
        self.resumeThreshold = resumeThreshold
        self.lowWatermark = lowWatermark
        self.target = target
        self.maximumPacketBytes = maximumPacketBytes
    }

    public init(
        startThreshold: TimeInterval = 1,
        resumeThreshold: TimeInterval = 2,
        lowWatermark: TimeInterval = 0.5,
        target: TimeInterval = 10,
        maximumPacketBytes: Int? = nil,
        maximumBackwardPacketBytes: Int
    ) {
        self.init(startThreshold: startThreshold, resumeThreshold: resumeThreshold,
                  lowWatermark: lowWatermark, target: target, maximumPacketBytes: maximumPacketBytes)
        self.maximumBackwardPacketBytes = max(0, maximumBackwardPacketBytes)
    }
}
