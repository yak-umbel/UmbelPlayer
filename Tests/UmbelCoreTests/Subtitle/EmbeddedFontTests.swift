import CoreGraphics
import CoreMedia
import XCTest
@testable import UmbelCore
@testable import UmbelFFmpegSupport

private final class FrozenHost: HostTimeSource, @unchecked Sendable {
  var now: CMTime { .zero }
}

final class EmbeddedFontTests: XCTestCase {
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func attachment(_ name: String?, _ type: String?) -> FFmpegAttachment {
    FFmpegAttachment(filename: name, mimeType: type, data: Data([1, 2, 3]))
  }

  /// Muxers disagree on the MIME type of a font; the extension settles it.
  /// Other attachments — cover art — are not fonts.
  func testFontsAreRecognisedByTypeOrExtension() {
    let fonts = EmbeddedFont.fonts(from: [
      attachment("a.bin", "application/x-truetype-font"),
      attachment("b.OTF", "application/octet-stream"),
      attachment("cover.jpg", "image/jpeg"),
      attachment(nil, "font/ttf"),
      attachment("notes.txt", nil),
    ])
    XCTAssertEqual(fonts.map(\.name), ["a.bin", "b.OTF", "attachment"])
  }

  func testTheFixtureCarriesItsFont() async throws {
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("styled_subs.mkv")))
    try await demux.open()
    addTeardownBlock { await demux.close() }
    let fonts = EmbeddedFont.fonts(from: await demux.attachments())
    let expected = try Data(contentsOf: fixture("fonts/Silkscreen-Regular.ttf"))
    XCTAssertEqual(fonts.map(\.name), ["Silkscreen-Regular.ttf"])
    XCTAssertEqual(fonts.first?.data, expected)
  }

  /// The line `{\fnSilkscreen}Embedded font` names a font found only in the
  /// file's attachment. Rendered through a session, it must come out as wide
  /// as libass draws it with that font — and not as wide as the fallback.
  func testAttachedFontReachesLibass() async throws {
    let size = CGSize(width: 640, height: 360)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture("styled_subs.mkv")),
      audioOutput: VirtualAudioOutput(hostTime: FrozenHost()), hostTime: FrozenHost())
    try await session.load()
    addTeardownBlock { await session.stop() }
    try await session.selectSubtitleTrack(UmbelTrack.ID(rawValue: 3))
    try await session.seek(to: CMTime(seconds: 5.5, preferredTimescale: 600))
    var drawn = CGRect.null
    for _ in 0..<100 {
      drawn = await session.renderSubtitles(in: size).bitmaps.map(\.frame)
        .reduce(CGRect.null) { $0.union($1) }
      if !drawn.isNull { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    // The same line through libass directly, with and without the font.
    let demux = DemuxSession(source: try UmbelFileSource(url: fixture("styled_subs.mkv")))
    try await demux.open()
    let header = try await demux.makeSubtitleDecoder(for: UmbelTrack.ID(rawValue: 3)).subtitleHeader
    await demux.close()
    let font = EmbeddedFont(
      name: "Silkscreen-Regular.ttf", data: try Data(contentsOf: fixture("fonts/Silkscreen-Regular.ttf")))
    func width(with fonts: [EmbeddedFont]) async -> CGFloat {
      let source = ASSSubtitleSource(header: header, fonts: fonts)
      await source.feed(DemuxPacket(
        trackID: UmbelTrack.ID(rawValue: 3),
        data: Data("3,0,Default,,0,0,0,,{\\fnSilkscreen}Embedded font".utf8),
        presentationTime: CMTime(seconds: 5, preferredTimescale: 1000),
        decodeTime: CMTime(seconds: 5, preferredTimescale: 1000),
        duration: CMTime(seconds: 1, preferredTimescale: 1000), isKeyframe: true))
      let frame = await source.render(
        at: CMTime(seconds: 5.5, preferredTimescale: 1000), in: size, videoSize: nil)
      return frame.bitmaps.map(\.frame).reduce(CGRect.null) { $0.union($1) }.width
    }
    let withFont = await width(with: [font])
    let fallback = await width(with: [])

    XCTAssertGreaterThan(abs(withFont - fallback), 10, "precondition: the fonts look different")
    XCTAssertEqual(drawn.width, withFont, accuracy: 2)
  }
}
