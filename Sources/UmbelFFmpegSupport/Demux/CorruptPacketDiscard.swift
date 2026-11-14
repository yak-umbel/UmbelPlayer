import FFmpeg

/// Whether the demuxer beneath drops the packets it marks as corrupt.
///
/// A packet cut short — the read under it failed midway — is marked corrupt.
/// No decoder can use it, and handed on it turns a network error into a
/// decoder error, so FFmpeg's own switch for this (`-fflags +discardcorrupt`)
/// is on. Except once the source has said it is at its end: nothing is cut
/// short by a failure then, and the packets the demuxer empties out as it
/// meets the end are the file's own. The last of them may be short only
/// because the file is, and dropping it loses the end of the file. The
/// switch is turned off at that point, and on again once the file is open —
/// finding its duration reads to the end of it — and by every seek.
///
/// The end is reported from inside the call that reads packets, before the
/// demuxer hands over what it was holding — a packet, then another, one to a
/// call — so it has to be turned off there, not after the call returns.
/// Everything here runs on the demuxer's own thread.
final class CorruptPacketDiscard {
  private var context: UnsafeMutablePointer<AVFormatContext>?

  /// Starts with the switch on, as it has to be while the file is probed.
  func attach(to context: UnsafeMutablePointer<AVFormatContext>) {
    self.context = context
    arm()
  }

  func arm() {
    context?.pointee.flags |= AVFMT_FLAG_DISCARD_CORRUPT
  }

  func disarmAtEnd() {
    context?.pointee.flags &= ~AVFMT_FLAG_DISCARD_CORRUPT
  }

  /// Before the format context is freed.
  func detach() {
    context = nil
  }
}
