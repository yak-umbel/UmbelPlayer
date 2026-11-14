import CoreGraphics
import CoreMedia
import Foundation
import UmbelASSSupport

/// One ASS track rendered by libass, with everything libass needs to do it.
///
/// An actor because libass objects are not thread-safe: the track is fed
/// packets and rendered from here only. Each source has its own library, so
/// nothing libass holds is shared between two of them.
internal actor ASSSubtitleSource {
  private let library = ASSLibrary()
  private let track: ASSTrack
  private let renderer: ASSRenderer
  private var frameSize: CGSize = .zero
  private var fontScale = 1.0
  private var lastBitmaps: [UmbelSubtitleBitmap] = []

  /// An embedded track: its header now, its events as packets arrive.
  init(header: String, fonts: [EmbeddedFont]) {
    Self.add(fonts, to: library)
    track = ASSTrack(library: library)
    track.processCodecPrivate(Data(header.utf8))
    renderer = ASSRenderer(library: library)
  }

  /// A whole script, as read from an external file. Nil if libass cannot
  /// read it.
  init?(script: Data, fonts: [EmbeddedFont]) {
    Self.add(fonts, to: library)
    guard let track = ASSTrack(library: library, scriptData: script) else { return nil }
    self.track = track
    // After reading: fonts from the script's own [Fonts] section have been
    // added to the library by now, and the renderer picks them up.
    renderer = ASSRenderer(library: library)
  }

  /// A packet of an embedded track, in the Matroska block format MKV stores.
  /// Events are kept across seeks — libass drops repeats by ReadOrder — so
  /// seeking back shows lines already seen at once.
  func feed(_ packet: DemuxPacket) {
    guard packet.presentationTime.isValid else { return }
    let duration = packet.duration.isValid ? packet.duration.seconds : 0
    track.processChunk(
      packet.data,
      startMilliseconds: Self.milliseconds(packet.presentationTime.seconds),
      durationMilliseconds: Self.milliseconds(duration))
  }

  /// The picture at `time`, reusing the last composite when libass reports
  /// no change.
  ///
  /// `videoSize` is the video's own resolution. libass uses it for effects
  /// that depend on the picture's aspect, which a scaled frame alone does not
  /// tell it.
  func render(
    at time: CMTime, in size: CGSize, videoSize: CGSize?, scale: Double = 1
  ) -> UmbelSubtitleFrame {
    var resized = false
    if scale != fontScale {
      renderer.setFontScale(scale)
      fontScale = scale
      resized = true
    }
    if size != frameSize {
      renderer.setFrameSize(width: Int(size.width), height: Int(size.height))
      if let videoSize {
        renderer.setStorageSize(width: Int(videoSize.width), height: Int(videoSize.height))
      }
      frameSize = size
      resized = true
    }
    let frame = renderer.render(track, atMilliseconds: Self.milliseconds(time.seconds))
    guard frame.isChanged || resized else {
      return UmbelSubtitleFrame(bitmaps: lastBitmaps, isChanged: false)
    }
    lastBitmaps = ASSComposer.compose(frame.images)
    return UmbelSubtitleFrame(bitmaps: lastBitmaps, isChanged: true)
  }

  /// A separate renderer keeps the screen's frame size and change cache intact.
  func snapshot(at time: CMTime, in size: CGSize, videoSize: CGSize?, scale: Double) -> [UmbelSubtitleBitmap] {
    let temporary = ASSRenderer(library: library)
    temporary.setFrameSize(width: Int(size.width), height: Int(size.height))
    if let videoSize {
      temporary.setStorageSize(width: Int(videoSize.width), height: Int(videoSize.height))
    }
    temporary.setFontScale(scale)
    return ASSComposer.compose(temporary.render(track, atMilliseconds: Self.milliseconds(time.seconds)).images)
  }

  private static func add(_ fonts: [EmbeddedFont], to library: ASSLibrary) {
    for font in fonts { library.addFont(named: font.name, data: font.data) }
  }

  private static func milliseconds(_ seconds: Double) -> Int64 {
    Int64((seconds * 1000).rounded())
  }
}
