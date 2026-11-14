import FFmpeg

/// The two codec operations, kept together so every decoder uses the same
/// send/receive boundary. Access is confined to the decoder's owner.
internal struct FFmpegCodecOperations {
  var send: (UnsafeMutablePointer<AVCodecContext>, UnsafePointer<AVPacket>?) -> Int32 = {
    avcodec_send_packet($0, $1)
  }
  var receive: (UnsafeMutablePointer<AVCodecContext>, UnsafeMutablePointer<AVFrame>) -> Int32 = {
    avcodec_receive_frame($0, $1)
  }
}
