import CoreMedia
import Foundation

/// Where the content handed to the outputs ends, so playback can be called
/// over when the clock gets there rather than when reading does.
///
/// Sound ends where its last frame's samples run out. A picture ends one
/// frame interval after its last frame starts: that frame is on screen
/// until the next would have been — the interval measured between the last
/// two frames, since the container's nominal rate may be missing or wrong.
internal struct PlayoutEnd: Sendable {
  private var soundEnd: CMTime?
  private var lastPictureTime: CMTime?
  private var pictureInterval: CMTime = .zero

  mutating func delivered(_ frame: AudioFrame) {
    guard frame.presentationTime.isValid, frame.sampleRate > 0 else { return }
    let end = frame.presentationTime
      + CMTime(seconds: Double(frame.frameCount) / frame.sampleRate, preferredTimescale: 1_000_000)
    soundEnd = soundEnd.map { max($0, end) } ?? end
  }

  /// Sound handed on still encoded, to the system player: it ends where
  /// the packet does.
  mutating func delivered(_ packet: DemuxPacket) {
    guard packet.presentationTime.isNumeric, packet.duration.isNumeric else { return }
    let end = packet.presentationTime + packet.duration
    soundEnd = soundEnd.map { max($0, end) } ?? end
  }

  mutating func delivered(_ frame: VideoFrame) {
    guard frame.isShown else { return }
    let time = frame.presentationTime
    guard time.isValid else { return }
    if let last = lastPictureTime {
      guard time > last else { return }
      pictureInterval = time - last
    }
    lastPictureTime = time
  }

  /// Nil until something has been delivered.
  var end: CMTime? {
    let pictureEnd = lastPictureTime.map { $0 + pictureInterval }
    switch (soundEnd, pictureEnd) {
    case let (sound?, picture?): return max(sound, picture)
    case let (sound?, nil): return sound
    case let (nil, picture?): return picture
    case (nil, nil): return nil
    }
  }
}
