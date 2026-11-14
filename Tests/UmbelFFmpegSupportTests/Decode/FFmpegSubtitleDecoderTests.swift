import XCTest
@testable import UmbelFFmpegSupport

private actor FixtureReader {
  private let data: Data
  private var position = 0
  let length: Int64?

  init(data: Data) {
    self.data = data
    self.length = Int64(data.count)
  }

  func read(maxLength: Int) -> Data {
    guard position < data.count else { return Data() }
    let end = min(position + maxLength, data.count)
    defer { position = end }
    return data.subdata(in: position..<end)
  }

  func seek(to offset: Int64) { position = min(Int(offset), data.count) }
}

/// A decoded subtitle as the tests look at it: times in milliseconds.
private struct Decoded {
  let start: Int64
  let end: Int64?
  let lines: [String]
  let bitmaps: [FFmpegSubtitleBitmap]
  let canvas: (width: Int, height: Int)
}

final class FFmpegSubtitleDecoderTests: XCTestCase {
  /// Decodes every packet of one subtitle stream and returns what came out,
  /// along with the header the decoder exposes.
  private func decodeStream(
    _ index: Int32, of fixture: String
  ) async throws -> (header: String, subtitles: [Decoded]) {
    let data = try Data(contentsOf: FixtureLocator.url(for: fixture))
    let reader = FixtureReader(data: data)
    let demuxer = FFmpegDemuxer(
      callbacks: FFmpegIOCallbacks(
        read: { maxLength in await reader.read(maxLength: maxLength) },
        seek: { offset in await reader.seek(to: offset) },
        totalLength: { await reader.length },
        canSeek: true),
      configuration: .init())
    try await demuxer.open()
    defer { Task { await demuxer.close() } }

    let decoder = try await demuxer.makeSubtitleDecoder(streamIndex: index)
    defer { decoder.close() }
    var decoded: [Decoded] = []
    while let packet = try await demuxer.readPacket() {
      guard packet.streamIndex == index else { continue }
      for subtitle in try decoder.decode(packet) {
        decoded.append(
          Decoded(
            start: subtitle.startMicroseconds / 1000,
            end: subtitle.endMicroseconds.map { $0 / 1000 },
            lines: subtitle.assLines,
            bitmaps: subtitle.bitmaps,
            canvas: (subtitle.canvasWidth, subtitle.canvasHeight)))
      }
    }
    return (decoder.subtitleHeader, decoded)
  }

  /// SRT's end time lives in the packet duration; dropping it would leave
  /// every cue open-ended.
  func testSubRipCarriesStartEndAndText() async throws {
    let (header, subtitles) = try await decodeStream(3, of: "multi_track.mkv")
    XCTAssertTrue(header.contains("PlayResY"), "FFmpeg writes a default header for SRT")
    XCTAssertEqual(subtitles.map(\.start), [0, 1000])
    XCTAssertEqual(subtitles.map(\.end), [1000, 2000])
    XCTAssertEqual(subtitles.map { $0.lines.count }, [1, 1])
    XCTAssertTrue(subtitles[0].lines[0].hasSuffix(",first line"), subtitles[0].lines[0])
  }

  func testSubRipMarkupBecomesOverrideTags() async throws {
    let (_, subtitles) = try await decodeStream(4, of: "styled_subs.mkv")
    XCTAssertTrue(subtitles[0].lines[0].hasSuffix(#",{\i1}tagged{\i0} line"#), subtitles[0].lines[0])
  }

  /// An ASS track's styles come from its own header, not a generated one.
  func testASSKeepsItsOwnHeaderAndTags() async throws {
    let (header, subtitles) = try await decodeStream(3, of: "styled_subs.mkv")
    XCTAssertTrue(header.contains("Style: Sign"), header)
    XCTAssertEqual(subtitles.map(\.start), [500, 2000, 4000, 5000])
    XCTAssertEqual(subtitles.map(\.end), [2000, 4000, 5000, 6000])
    XCTAssertTrue(subtitles[0].lines[0].contains(#"{\i1}italic"#), subtitles[0].lines[0])
    XCTAssertTrue(subtitles[1].lines[0].contains(",Sign,"), subtitles[1].lines[0])
  }

  func testMovText() async throws {
    let (_, subtitles) = try await decodeStream(2, of: "movtext_subs.mp4")
    XCTAssertEqual(subtitles.first?.start, 500)
    XCTAssertEqual(subtitles.first?.end, 1500)
    XCTAssertTrue(subtitles.first?.lines.first?.hasSuffix(",mov text line") == true)
  }

  func testWebVTT() async throws {
    let (_, subtitles) = try await decodeStream(2, of: "webvtt_subs.mkv")
    XCTAssertEqual(subtitles.first?.start, 500)
    XCTAssertEqual(subtitles.first?.end, 1500)
    let line = try XCTUnwrap(subtitles.first?.lines.first)
    XCTAssertTrue(line.contains(#"{\b1}bold{\b0}"#), line)
  }

  func testRejectsANonSubtitleStream() async throws {
    do {
      _ = try await decodeStream(0, of: "multi_track.mkv")
      XCTFail("a video stream is not a subtitle stream")
    } catch FFmpegDecoderError.notASubtitleStream {
    }
  }

  // ── Bitmap subtitles ─────────────────────────────────
  // The fixtures hold two solid blocks on a 320×240 canvas: white at
  // (110, 200) 100×20 from 0.5 to 2.0 s, red at (40, 20) 60×30 from 2.5 to 3.5 s.

  /// PGS shows each event until the next, and clears the screen with an
  /// event that has nothing in it. Dropping those would leave every line up
  /// until the next one appears.
  func testPGSShowsAndClears() async throws {
    let (_, subtitles) = try await decodeStream(1, of: "pgs_subs.mkv")
    XCTAssertEqual(subtitles.map(\.start), [500, 2000, 2500, 3500])
    XCTAssertEqual(subtitles.map(\.end), [nil, nil, nil, nil], "PGS says nothing of when an event ends")
    XCTAssertEqual(subtitles.map(\.bitmaps.count), [1, 0, 1, 0], "shown, cleared, shown, cleared")
    XCTAssertTrue(subtitles.allSatisfy(\.lines.isEmpty))
    guard subtitles.map(\.bitmaps.count) == [1, 0, 1, 0] else { return }

    let white = subtitles[0].bitmaps[0]
    XCTAssertEqual([white.x, white.y, white.width, white.height], [110, 200, 100, 20])
    XCTAssertEqual(subtitles[0].canvas.width, 320)
    XCTAssertEqual(subtitles[0].canvas.height, 240)
    XCTAssertEqual(pixel(of: white, x: 50, y: 10), [255, 255, 255, 255], "white, opaque")

    let red = subtitles[2].bitmaps[0]
    XCTAssertEqual([red.x, red.y, red.width, red.height], [40, 20, 60, 30])
    let redPixel = pixel(of: red, x: 30, y: 15)
    XCTAssertGreaterThan(redPixel[2], 200, "red channel")
    XCTAssertLessThan(redPixel[0], 40, "blue channel")
    XCTAssertLessThan(redPixel[1], 40, "green channel")
  }

  /// DVD subtitles carry their own end time, counted in 1024/90000 s steps —
  /// about 11 ms, so it lands just short of the exact value.
  func testDVDSubtitlesCarryTheirEnd() async throws {
    let (_, subtitles) = try await decodeStream(1, of: "dvd_subs.mkv")
    let shown = subtitles.filter { !$0.bitmaps.isEmpty }
    XCTAssertEqual(shown.map(\.start), [500, 2500])
    guard shown.count == 2 else { return XCTFail("two events shown, got \(shown.count)") }
    for (event, expected) in zip(shown, [2000, 3500] as [Int64]) {
      let end = try XCTUnwrap(event.end, "DVD subtitles say when they end")
      XCTAssertEqual(Double(end), Double(expected), accuracy: 12)
    }
    let white = shown[0].bitmaps[0]
    XCTAssertEqual([white.x, white.y, white.width, white.height], [110, 200, 100, 20])
    XCTAssertEqual(shown[0].canvas.width, 320)
    XCTAssertGreaterThan(pixel(of: white, x: 50, y: 10)[0], 200)
  }

  /// DVB gives every event an end — the page timeout, thirty seconds here —
  /// that is only an upper bound: the next event replaces it. Timestamps are
  /// the file's own; this one starts near 101.39 s.
  func testDVBEventsCarryTheirTimeoutAndCanvas() async throws {
    let (_, subtitles) = try await decodeStream(2, of: "dvb_subs_offset.ts")
    XCTAssertEqual(subtitles.map(\.start), [101_900, 103_400, 103_900, 104_900])
    XCTAssertEqual(subtitles.map(\.end), [131_900, 133_400, 133_900, 134_900])
    XCTAssertEqual(subtitles.map(\.bitmaps.count), [1, 0, 1, 0])
    guard subtitles.count == 4 else { return }
    let white = subtitles[0].bitmaps[0]
    XCTAssertEqual([white.x, white.y, white.width, white.height], [110, 200, 100, 20])
    XCTAssertEqual(subtitles[0].canvas.width, 320, "from the display definition segment")
    XCTAssertEqual(subtitles[0].canvas.height, 240)
  }

  /// Bitmap formats replace the whole picture with each event; text ones
  /// may overlap. The decoder says which it is.
  func testDecoderSaysWhetherItsFormatIsBitmap() async throws {
    let expectations: [(fixture: String, stream: Int32, isBitmap: Bool)] = [
      ("pgs_subs.mkv", 1, true), ("dvd_subs.mkv", 1, true), ("dvb_subs_offset.ts", 2, true),
      ("multi_track.mkv", 3, false), ("styled_subs.mkv", 3, false),
    ]
    for expected in expectations {
      let data = try Data(contentsOf: FixtureLocator.url(for: expected.fixture))
      let reader = FixtureReader(data: data)
      let demuxer = FFmpegDemuxer(
        callbacks: FFmpegIOCallbacks(
          read: { maxLength in await reader.read(maxLength: maxLength) },
          seek: { offset in await reader.seek(to: offset) },
          totalLength: { await reader.length },
          canSeek: true),
        configuration: .init())
      try await demuxer.open()
      let decoder = try await demuxer.makeSubtitleDecoder(streamIndex: expected.stream)
      XCTAssertEqual(decoder.isBitmap, expected.isBitmap, expected.fixture)
      decoder.close()
      await demuxer.close()
    }
  }

  /// Colours come out premultiplied: a half-transparent entry is dimmed.
  /// Checked on the conversion itself, since neither fixture has one.
  func testPaletteIsPremultiplied() {
    let entry: UInt32 = 0x80_FF_40_00  // alpha 128, red 255, green 64, blue 0
    XCTAssertEqual(FFmpegSubtitleDecoder.premultipliedBGRA(entry), [0, 32, 128, 128])
  }

  /// B, G, R, A of one pixel.
  private func pixel(of bitmap: FFmpegSubtitleBitmap, x: Int, y: Int) -> [UInt8] {
    let offset = (y * bitmap.width + x) * 4
    return Array(bitmap.pixels[offset..<offset + 4])
  }
}
