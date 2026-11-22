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
  private var drawn: DrawnPicture?
  private let meter: SubtitleRenderMeter
  /// The host's fonts this source holds. A font cannot be taken out of the
  /// library again, so this only grows.
  private var hostFonts: UmbelSubtitleFonts

  /// How often a line that changes with time is drawn again, at most: every
  /// 16 ms of subtitle time, about 60 a second. A video shows a new picture
  /// no more often than that, and a display that refreshes faster would only
  /// ask libass for pictures nobody sees.
  private static let animationStep: Int64 = 16

  /// The last picture libass drew, and what makes it good for other moments.
  private struct DrawnPicture {
    let span: ASSPictureSpan
    let time: Int64

    /// Within the span the same events are on screen, so a picture of lines
    /// that hold still is right for all of it. Lines that move are right for
    /// one step of time after the moment drawn, and not for earlier ones.
    func serves(_ moment: Int64) -> Bool {
      guard span.contains(moment) else { return false }
      return !span.isAnimated || (moment >= time && moment - time < ASSSubtitleSource.animationStep)
    }
  }

  /// What this source's drawings have cost, with those of every other source
  /// that shares its meter.
  var statistics: UmbelSubtitleRenderStatistics { meter.statistics }

  /// An embedded track: its header now, its events as packets arrive.
  init(
    header: String, fonts: [EmbeddedFont], hostFonts: UmbelSubtitleFonts = UmbelSubtitleFonts(),
    meter: SubtitleRenderMeter = SubtitleRenderMeter()
  ) {
    self.meter = meter
    self.hostFonts = hostFonts
    Self.add(fonts, to: library)
    Self.add(hostFonts, to: library)
    track = ASSTrack(library: library)
    track.processCodecPrivate(Data(header.utf8))
    renderer = ASSRenderer(library: library, defaultFamily: hostFonts.defaultFamily)
  }

  /// A whole script, as read from an external file. Nil if libass cannot
  /// read it.
  init?(
    script: Data, fonts: [EmbeddedFont], hostFonts: UmbelSubtitleFonts = UmbelSubtitleFonts(),
    meter: SubtitleRenderMeter = SubtitleRenderMeter()
  ) {
    self.meter = meter
    self.hostFonts = hostFonts
    Self.add(fonts, to: library)
    Self.add(hostFonts, to: library)
    guard let track = ASSTrack(library: library, scriptData: script) else { return nil }
    self.track = track
    // After reading: fonts from the script's own [Fonts] section have been
    // added to the library by now, and the renderer picks them up.
    renderer = ASSRenderer(library: library, defaultFamily: hostFonts.defaultFamily)
  }

  /// A packet of an embedded track, in the Matroska block format MKV stores.
  /// Events are kept across seeks — libass drops repeats by ReadOrder — so
  /// seeking back shows lines already seen at once.
  func feed(_ packet: DemuxPacket) {
    guard packet.presentationTime.isValid else { return }
    let start = Self.milliseconds(packet.presentationTime.seconds)
    let duration = Self.milliseconds(packet.duration.isValid ? packet.duration.seconds : 0)
    track.processChunk(packet.data, startMilliseconds: start, durationMilliseconds: duration)
    // A line that would be on screen during the picture drawn changes it.
    if let current = drawn, current.span.overlaps(eventStart: start, duration: duration) {
      drawn = nil
    }
  }

  /// The picture at `time`.
  ///
  /// libass lays every line out again on each call, and a display asks on
  /// every tick, so the last picture is handed back for as long as it holds:
  /// while no event starts or ends, the size and scale are the same, and no
  /// line on screen moves. A line that moves is drawn again once per step of
  /// time. Past that, libass is asked, and says whether it changed.
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
    let moment = Self.milliseconds(time.seconds)
    if !resized, let current = drawn, current.serves(moment) {
      return UmbelSubtitleFrame(bitmaps: lastBitmaps, isChanged: false)
    }
    let frame = renderer.render(track, atMilliseconds: moment)
    meter.record(frame)
    drawn = DrawnPicture(span: track.pictureSpan(at: moment), time: moment)
    guard frame.isChanged || resized else {
      return UmbelSubtitleFrame(bitmaps: lastBitmaps, isChanged: false)
    }
    lastBitmaps = ASSComposer.compose(frame.images)
    return UmbelSubtitleFrame(bitmaps: lastBitmaps, isChanged: true)
  }

  /// Gives this track the host's fonts, from the next picture on: the one
  /// drawn without them is not good any more.
  ///
  /// Fonts it already holds are not added again.
  func use(_ fonts: UmbelSubtitleFonts) {
    let held = hostFonts.fonts.count
    for data in fonts.fonts where !hostFonts.fonts.contains(data) {
      library.addFont(named: Self.hostFontName(hostFonts.fonts.count), data: data)
      hostFonts.fonts.append(data)
    }
    let added = hostFonts.fonts.count > held
    guard added || fonts.defaultFamily != hostFonts.defaultFamily else { return }
    hostFonts.defaultFamily = fonts.defaultFamily
    if renderer.defaultFamily != fonts.defaultFamily {
      renderer.defaultFamily = fonts.defaultFamily   // reloads the fonts
    } else {
      renderer.reloadFonts()
    }
    drawn = nil
  }

  /// A separate renderer keeps the screen's frame size and change cache intact.
  func snapshot(at time: CMTime, in size: CGSize, videoSize: CGSize?, scale: Double) -> [UmbelSubtitleBitmap] {
    let temporary = ASSRenderer(library: library, defaultFamily: hostFonts.defaultFamily)
    temporary.setFrameSize(width: Int(size.width), height: Int(size.height))
    if let videoSize {
      temporary.setStorageSize(width: Int(videoSize.width), height: Int(videoSize.height))
    }
    temporary.setFontScale(scale)
    let frame = temporary.render(track, atMilliseconds: Self.milliseconds(time.seconds))
    meter.record(frame)
    return ASSComposer.compose(frame.images)
  }

  private static func add(_ fonts: [EmbeddedFont], to library: ASSLibrary) {
    for font in fonts { library.addFont(named: font.name, data: font.data) }
  }

  private static func add(_ fonts: UmbelSubtitleFonts, to library: ASSLibrary) {
    for (index, data) in fonts.fonts.enumerated() {
      library.addFont(named: hostFontName(index), data: data)
    }
  }

  /// Only an identifier for libass: the families come from the files.
  private static func hostFontName(_ index: Int) -> String { "host-font-\(index)" }

  private static func milliseconds(_ seconds: Double) -> Int64 {
    Int64((seconds * 1000).rounded())
  }
}
