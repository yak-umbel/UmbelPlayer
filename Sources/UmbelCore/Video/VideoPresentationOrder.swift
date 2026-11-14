import CoreMedia
import CoreVideo

/// Only a real decode timestamp can release reordered pictures. Containers
/// may omit the initial timestamps; later gaps or reversals need recovery.
internal struct VideoDecodeWatermark {
  private var last = CMTime.invalid

  mutating func accept(presentation: CMTime, decode: CMTime) throws -> CMTime {
    guard presentation.isNumeric,
          decode.isNumeric
            ? presentation >= decode && (!last.isNumeric || decode >= last)
            : !decode.isValid && !last.isNumeric else {
      throw UmbelError.videoRenderUnavailable(reason: "system pixel route requires safe ordered decode timestamps")
    }
    if decode.isNumeric { last = decode }
    return decode
  }

  mutating func reset() { last = .invalid }
}

/// Native callbacks may arrive in decode order. A decode-time watermark
/// makes earlier presentation times safe to submit without waiting forever.
internal struct VideoPresentationOrder {
  private var frames: [VideoFrame] = []
  private var retainedBytes = 0
  private let limitBytes: Int

  init(limitBytes: Int = 64 * 1024 * 1024) { self.limitBytes = limitBytes }

  mutating func append(_ pictures: [VideoFrame]) throws {
    for frame in pictures {
      guard frame.presentationTime.isNumeric else {
        throw UmbelError.videoRenderUnavailable(reason: "system decoder returned an invalid presentation timestamp")
      }
      frames.append(frame)
      retainedBytes += Self.size(of: frame)
      guard frames.count <= 32, retainedBytes <= limitBytes else {
        throw UmbelError.videoRenderUnavailable(reason: "system presentation reorder surface budget exceeded")
      }
    }
  }

  mutating func take(through watermark: CMTime) -> [VideoFrame] {
    guard watermark.isNumeric else { return [] }
    frames.sort { $0.presentationTime < $1.presentationTime }
    let result = Array(frames.prefix { $0.presentationTime <= watermark })
    retainedBytes -= result.reduce(0) { $0 + Self.size(of: $1) }
    frames.removeFirst(result.count)
    return result
  }

  mutating func drain() -> [VideoFrame] {
    let result = frames.sorted { $0.presentationTime < $1.presentationTime }
    reset()
    return result
  }

  mutating func reset() { frames.removeAll(keepingCapacity: true); retainedBytes = 0 }

  private static func size(of frame: VideoFrame) -> Int {
    guard let buffer = frame.pixelBuffer else { return 0 }
    return max(CVPixelBufferGetDataSize(buffer), frame.width * frame.height * 3)
  }
}
