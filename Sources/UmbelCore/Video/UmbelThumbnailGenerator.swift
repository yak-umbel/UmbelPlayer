import CoreGraphics
import CoreMedia
import Foundation
import Metal

/// A video-only preview and the presentation time of the picture it contains.
public struct UmbelThumbnail: Sendable {
  public let image: CGImage
  public let presentationTime: CMTime
}

/// Failures specific to generating a timeline preview.
public enum UmbelThumbnailError: Error, Sendable, Equatable {
  case invalidTime
  case invalidMaximumSize
  case seekUnsupported
  case noVideo
  case systemDisplayRequired
}

/// Generates independent video previews without seeking a playback session.
///
/// The factory must return a fresh, exclusively owned source for each request.
/// This generator invalidates that source after use. Factories and sources should
/// cooperate with cancellation and invalidate outstanding I/O promptly.
/// One request runs at a time; waiting requests may be cancelled independently.
public actor UmbelThumbnailGenerator {
  private let sourceFactory: @Sendable () async throws -> any UmbelSource
  private let configuration: DemuxConfiguration
  private var active = false
  private var waiting: [(UUID, CheckedContinuation<Void, any Error>)] = []

  public init(
    sourceFactory: @escaping @Sendable () async throws -> any UmbelSource,
    configuration: DemuxConfiguration = .init()
  ) {
    self.sourceFactory = sourceFactory
    self.configuration = configuration
  }

  /// Returns the first picture at or after `time`, or the last at end of stream.
  /// The result fits whole pixels within `maximumSize`, without upscaling.
  /// Its SDR image contains video only, with neutral picture adjustments.
  public func thumbnail(
    at time: CMTime, maximumSize: CGSize = CGSize(width: 320, height: 180)
  ) async throws -> UmbelThumbnail {
    guard time.isNumeric, time.seconds.isFinite, time >= .zero else {
      throw UmbelThumbnailError.invalidTime
    }
    guard maximumSize.width.isFinite, maximumSize.height.isFinite,
          maximumSize.width >= 1, maximumSize.height >= 1 else {
      throw UmbelThumbnailError.invalidMaximumSize
    }
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    let scope = ThumbnailSourceScope()
    return try await withTaskCancellationHandler {
      do {
        let factory = sourceFactory
        let source = try await scope.perform {
          let source = try await factory()
          try await scope.own(source)
          return source
        }
        try Task.checkCancellation()
        guard let randomAccess = source as? any UmbelRandomAccessSource else {
          throw UmbelThumbnailError.seekUnsupported
        }
        let demux = DemuxSession(
          source: ThumbnailSource(source: randomAccess, scope: scope), configuration: configuration)
        let result: UmbelThumbnail
        do {
          result = try await makeThumbnail(demux: demux, at: time, maximumSize: maximumSize)
          await demux.close()
        } catch {
          await demux.close()
          throw error
        }
        await scope.close()
        try Task.checkCancellation()
        return result
      } catch {
        await scope.close()
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await scope.cancel() }
    }
  }

  private func makeThumbnail(
    demux: DemuxSession, at time: CMTime, maximumSize: CGSize
  ) async throws -> UmbelThumbnail {
    try await demux.open()
    try Task.checkCancellation()
    guard await demux.isSeekable else { throw UmbelThumbnailError.seekUnsupported }
    let duration = await demux.duration
    guard duration.isNumeric, duration.seconds.isFinite else {
      throw UmbelThumbnailError.seekUnsupported
    }
    guard time <= duration else { throw UmbelThumbnailError.invalidTime }
    guard let track = await demux.tracks.first(where: { $0.kind == .video }) else {
      throw UmbelThumbnailError.noVideo
    }
    guard track.video?.dynamicHDR?.requiresSystemDisplay != true else {
      throw UmbelThumbnailError.systemDisplayRequired
    }
    try await demux.seek(to: time)
    try Task.checkCancellation()
    let decoder = VideoDecodeSession(
      decoder: try await demux.makeVideoDecoder(for: track.id),
      baseLayer: track.video?.dynamicHDR?.baseLayer,
      deinterlacer: VideoDeinterlacer(setting: DeinterlaceSwitch(), nominalFrameRate: track.video?.nominalFrameRate))
    do {
      let frame = try await picture(demux: demux, decoder: decoder, track: track.id, at: time)
      await decoder.close()
      try Task.checkCancellation()
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw UmbelError.videoRenderUnavailable(reason: "no Metal device for timeline previews")
      }
      let display = frame.displaySize
      guard display.width.isFinite, display.height.isFinite,
            display.width > 0, display.height > 0 else {
        throw UmbelError.snapshotUnavailable(reason: "the preview picture has no display size")
      }
      let scale = min(1, maximumSize.width / display.width, maximumSize.height / display.height)
      let size = CGSize(width: max(1, (display.width * scale).rounded(.down)),
                        height: max(1, (display.height * scale).rounded(.down)))
      let image = try FrameSnapshot.image(of: frame, size: size, subtitles: [], device: device)
      try Task.checkCancellation()
      return UmbelThumbnail(image: image, presentationTime: frame.presentationTime)
    } catch {
      await decoder.close()
      throw error
    }
  }

  private func picture(
    demux: DemuxSession, decoder: VideoDecodeSession, track: UmbelTrack.ID, at time: CMTime
  ) async throws -> VideoFrame {
    var last: VideoFrame?
    while let packet = try await demux.nextPacket() {
      try Task.checkCancellation()
      guard packet.trackID == track else { continue }
      for frame in try await decoder.decode(packet) where frame.presentationTime.isNumeric {
        try Task.checkCancellation()
        if frame.presentationTime >= time { return frame }
        last = frame
      }
    }
    for frame in try await decoder.drain() where frame.presentationTime.isNumeric {
      try Task.checkCancellation()
      if frame.presentationTime >= time { return frame }
      last = frame
    }
    guard let last else { throw UmbelError.snapshotUnavailable(reason: "no decodable preview picture") }
    return last
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if !active { active = true; return }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
    waiting.remove(at: index).1.resume(throwing: CancellationError())
  }

  private func release() {
    if waiting.isEmpty { active = false }
    else { waiting.removeFirst().1.resume() }
  }
}
