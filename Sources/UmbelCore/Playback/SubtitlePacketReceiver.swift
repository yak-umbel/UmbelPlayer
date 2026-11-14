import Foundation

/// Where packets from the selected embedded subtitle track go.
///
/// Implemented by `SubtitleDecodeSession`. It stays internal: what a host
/// receives is decoded cues (`PlaybackSession.currentSubtitleCues`), never raw
/// packets — the text subtitle slice settled that shape.
internal protocol SubtitlePacketReceiver: AnyObject, Sendable {
  func receive(_ packet: DemuxPacket) async
}
