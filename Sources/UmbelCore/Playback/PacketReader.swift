import CoreMedia
import Foundation

/// Reads packets from the demuxer into the cache, as far as the cache's
/// target: the network-to-cache half of `PlaybackPipeline`.
///
/// Reading stops at the target and resumes below it. Polling rather than a
/// continuation: it only happens while the cache is full, twenty
/// milliseconds apart.
internal actor PacketReader {
  private let demux: DemuxSession
  private let cache: PacketCache
  private var task: Task<Void, Never>?
  /// Filters what reading brings in until both chains reach a seek target.
  private var preroll: PrerollFilter?

  internal init(demux: DemuxSession, cache: PacketCache) {
    self.demux = demux
    self.cache = cache
  }

  /// After a seek, reading may start before the target; see `PrerollFilter`.
  internal func armPreroll(
    at target: CMTime, audioFrom audioTarget: CMTime? = nil, video: UmbelTrack.ID?, audio: UmbelTrack.ID?
  ) {
    preroll = PrerollFilter(target: target, audioTarget: audioTarget, video: video, audio: audio)
  }

  /// Reading still filters for a seek's target; see `PrerollFilter`.
  internal var isFiltering: Bool { preroll != nil }

  /// The cache was emptied: what was held back belongs to where reading was.
  internal func clearPreroll() {
    preroll = nil
  }

  /// Reads until the input is over, unless already reading. `onRead` follows
  /// each packet into the cache; `onEnd` hears how the input ended — nil at
  /// the end of the content, the error of a read that failed for good.
  internal func start(
    onRead: @escaping @Sendable () async -> Void,
    onEnd: @escaping @Sendable (Error?) async -> Void
  ) {
    guard task == nil else { return }
    let demux = self.demux
    let cache = self.cache
    task = Task { [weak self] in
      while !Task.isCancelled {
        if !(await cache.prepareToRead()) {
          try? await Task.sleep(nanoseconds: 20_000_000)
          continue
        }
        do {
          guard let packet = try await demux.nextPacket() else {
            await self?.end(failedWith: nil, onRead: onRead, onEnd: onEnd)
            return
          }
          for admitted in await self?.admit(packet) ?? [] {
            guard await Self.enqueue(admitted, in: cache, onRead: onRead) else { return }
          }
        } catch {
          await self?.end(failedWith: error, onRead: onRead, onEnd: onEnd)
          return
        }
      }
    }
  }

  /// Asks reading to stop; `waitUntilStopped()` waits for it. A read the
  /// source is blocked in is given up, the source staying in use: whoever
  /// stops reading seeks or closes next, so what that read would have
  /// brought is not needed.
  internal func cancel() async {
    task?.cancel()
    await demux.abandonReading()
  }

  internal func waitUntilStopped() async {
    await task?.value
    task = nil
    await demux.resumeReading()
  }

  /// Content that ended before the target still hands over what was held,
  /// so the last picture can show.
  private func end(
    failedWith error: Error?, onRead: @Sendable () async -> Void,
    onEnd: @Sendable (Error?) async -> Void
  ) async {
    let held = preroll?.drain() ?? []
    preroll = nil
    for packet in held {
      guard await Self.enqueue(packet, in: cache, onRead: onRead) else { return }
    }
    await onEnd(error)
  }

  /// A seek can release a whole preroll group. Admit it one packet at a
  /// time so that it cannot bypass the same bound as ordinary reading.
  private static func enqueue(
    _ packet: DemuxPacket, in cache: PacketCache, onRead: @Sendable () async -> Void
  ) async -> Bool {
    while !Task.isCancelled {
      if await cache.append(packet) {
        await onRead()
        return true
      }
      try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
  }

  private func admit(_ packet: DemuxPacket) -> [DemuxPacket] {
    guard var filter = preroll else { return [packet] }
    let admitted = filter.admit(packet)
    preroll = filter.isFinished ? nil : filter
    return admitted
  }
}
