import FFmpeg
import Foundation

/// Drives the codec's send/receive protocol for both audio and video.
/// The owning decoder serializes access to its context and conversions.
internal final class FFmpegDecodePump<Output> {
  // A conforming codec needs only one receive pass before a send retry.
  // Allow several passes for recovery, but never spin on a broken codec.
  private let maximumSendAttempts = 8
  // A failed frame may leave more input pending. Try past isolated damage,
  // with a separate bound when receive itself cannot make progress.
  private let maximumConsecutiveReceiveErrors = 16
  /// Healthy frames recovered before a rejected packet still belong to the
  /// stream. Keep them for the next successful decode or drain.
  private var pendingOutputs: [Output] = []

  func reset() { pendingOutputs.removeAll() }

  func decode(
    context: UnsafeMutablePointer<AVCodecContext>, packet: UnsafePointer<AVPacket>,
    operations: FFmpegCodecOperations, onDamagedFrame: () -> Void = {},
    convert: (UnsafeMutablePointer<AVFrame>) throws -> Output?
  ) throws -> [Output] {
    guard let frame = av_frame_alloc() else {
      throw FFmpegDecoderError.receiveFailed(-ENOMEM)
    }
    defer {
      var owned: UnsafeMutablePointer<AVFrame>? = frame
      av_frame_free(&owned)
    }
    var outputs = pendingOutputs
    pendingOutputs.removeAll()

    func receiveAll() throws {
      var consecutiveErrors = 0
      while true {
        let status = operations.receive(context, frame)
        defer { av_frame_unref(frame) }
        if status == FFmpegErrorCode.tryAgainRaw || status == FFmpegErrorCode.endOfFileRaw {
          return
        }
        if status < 0 {
          onDamagedFrame()
          consecutiveErrors += 1
          guard consecutiveErrors < maximumConsecutiveReceiveErrors else {
            throw FFmpegDecoderError.receiveFailed(status)
          }
          continue
        }
        consecutiveErrors = 0
        if let output = try convert(frame) { outputs.append(output) }
      }
    }

    for _ in 0..<maximumSendAttempts {
      let status = operations.send(context, packet)
      if status == FFmpegErrorCode.tryAgainRaw {
        // The packet was NOT accepted. Keep it intact, take pending output,
        // then send this exact packet again, including when it signals EOF.
        try receiveAll()
        continue
      }
      guard status >= 0 else {
        // Other send failures can occur after input was accepted. Never
        // resend it: the next decode call can recover any pending input.
        if status != FFmpegErrorCode.endOfFileRaw { pendingOutputs = outputs }
        throw FFmpegDecoderError.sendFailed(status)
      }
      try receiveAll()
      return outputs
    }
    throw FFmpegDecoderError.sendFailed(FFmpegErrorCode.tryAgainRaw)
  }
}
