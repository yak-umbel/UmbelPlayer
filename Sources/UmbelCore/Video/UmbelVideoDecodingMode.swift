/// Packet scheduling for video decoded by the playback engine.
/// Both modes decode outside the UI thread; hardware preference is independent.
public enum UmbelVideoDecodingMode: String, Sendable {
  case synchronous
  /// One packet of lookahead on a private serial queue, with at most two
  /// packet jobs outstanding. This does not enable native callback decoding.
  case asynchronous
}

/// The selected video route, including while temporarily suspended.
public enum UmbelVideoDecodingStatus: String, Sendable {
  /// Before successful loading, after stopping, or without a video output.
  case inactive
  case synchronous
  case asynchronous
  /// Compressed pictures are decoded and presented by the system.
  case systemManaged
}
