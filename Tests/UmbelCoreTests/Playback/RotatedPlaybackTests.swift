import CoreGraphics
import CoreMedia
import Metal
import XCTest
@testable import UmbelCore

/// The same 128×64 picture, bright in its top-left quadrant, declared turned
/// in four ways; played through a whole session.
final class RotatedPlaybackTests: XCTestCase {
  private final class HeldTime: HostTimeSource, @unchecked Sendable {
    var now: CMTime { .zero }
  }

  private let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)

  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(name)
  }

  private func session(
    for name: String, outputSize: CGSize? = nil
  ) async throws -> PlaybackSession {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let renderer = try OffscreenVideoRenderer(device: device, outputSize: outputSize, tolerance: tolerance)
    let session = PlaybackSession(
      source: try UmbelFileSource(url: fixture(name)), videoRenderer: renderer, hostTime: HeldTime())
    try await session.load()
    addTeardownBlock { await session.stop() }
    return session
  }

  private func showFirstPicture(_ session: PlaybackSession) async throws {
    try await session.play()
    for _ in 0..<100 {
      if try await session.renderVideoFrame() != nil { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("no picture was presented")
  }

  private func green(_ image: CGImage, _ x: Int, _ y: Int) throws -> Int {
    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
    return Int(bytes[y * image.bytesPerRow + x * 4 + 1])
  }

  func testASnapshotIsTurned() async throws {
    let session = try await session(for: "rotation_cw90.mp4")
    try await showFirstPicture(session)
    let image = try await session.snapshot()
    XCTAssertEqual(image.width, 64)
    XCTAssertEqual(image.height, 128)
    XCTAssertGreaterThan(try green(image, 48, 32), 200, "the stored top-left is now top-right")
    XCTAssertLessThan(try green(image, 16, 32), 60)
    XCTAssertLessThan(try green(image, 16, 96), 60)
  }

  /// The ratio shapes the picture as shown: height times the ratio wide. The
  /// stored picture is 128×64, so an unturned one becomes 64×64 and a turned
  /// one, 64×128 as shown, becomes 128×128.
  func testTheAspectRatioOverrideShapesTheTurnedPicture() async throws {
    let turned = try await session(for: "rotation_cw90.mp4")
    try await showFirstPicture(turned)
    await turned.setAspectRatio(1)
    let turnedImage = try await turned.snapshot()
    XCTAssertEqual(turnedImage.width, 128)
    XCTAssertEqual(turnedImage.height, 128)

    let plain = try await session(for: "rotation_none.mp4")
    try await showFirstPicture(plain)
    await plain.setAspectRatio(1)
    let plainImage = try await plain.snapshot()
    XCTAssertEqual(plainImage.width, 64)
    XCTAssertEqual(plainImage.height, 64)
  }

  /// A 128×128 view: the turned 64×128 picture fits at half the width, and
  /// fills by being drawn twice as large, its top and bottom cut off.
  func testFitAndFillLayTheTurnedPictureOut() async throws {
    let session = try await session(for: "rotation_cw90.mp4", outputSize: CGSize(width: 128, height: 128))
    try await showFirstPicture(session)
    let fitted = await session.pictureFrame
    let fit = try XCTUnwrap(fitted)
    XCTAssertEqual(fit.minX, 0.25, accuracy: 0.01)
    XCTAssertEqual(fit.minY, 0, accuracy: 0.01)
    XCTAssertEqual(fit.width, 0.5, accuracy: 0.01)
    XCTAssertEqual(fit.height, 1, accuracy: 0.01)

    await session.setPictureScaling(.fill)
    let filled = await session.pictureFrame
    let fill = try XCTUnwrap(filled)
    XCTAssertEqual(fill.minX, 0, accuracy: 0.01)
    XCTAssertEqual(fill.minY, -0.5, accuracy: 0.01)
    XCTAssertEqual(fill.width, 1, accuracy: 0.01)
    XCTAssertEqual(fill.height, 2, accuracy: 0.01)
  }

  /// With no view size of its own, the target is made before the first frame
  /// from the track: in the turned shape, so the turned picture fills it
  /// rather than being boxed into a sideways one.
  func testATargetSizedFromTheTrackTakesTheTurnedShape() async throws {
    let session = try await session(for: "rotation_cw90.mp4")
    try await showFirstPicture(session)
    let shown = await session.pictureFrame
    let frame = try XCTUnwrap(shown)
    XCTAssertEqual(frame.minX, 0, accuracy: 0.01)
    XCTAssertEqual(frame.minY, 0, accuracy: 0.01)
    XCTAssertEqual(frame.width, 1, accuracy: 0.01)
    XCTAssertEqual(frame.height, 1, accuracy: 0.01)
  }

  /// Subtitles stay upright over the turned picture, laid out against the
  /// video's resolution as shown.
  func testSubtitlesAreLaidOutAgainstTheTurnedVideoSize() async throws {
    let turned = try await session(for: "rotation_cw90.mp4")
    let turnedSize = await turned.videoSize
    XCTAssertEqual(turnedSize, CGSize(width: 64, height: 128))
    let plain = try await session(for: "rotation_none.mp4")
    let plainSize = await plain.videoSize
    XCTAssertEqual(plainSize, CGSize(width: 128, height: 64))
  }

  /// A red square drawn by an ASS script, in the middle of the picture, its
  /// edges blurred: libass scales blur by the frame's height against the
  /// video's, so a wrong video size shows as a wider or narrower blur.
  private func squareScript() throws -> URL {
    let script = """
      [Script Info]
      ScriptType: v4.00+
      PlayResX: 384
      PlayResY: 288

      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, \
      Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, \
      Alignment, MarginL, MarginR, MarginV, Encoding
      Style: Default,Arial,20,&H000000FF,&H000000FF,&H000000FF,&H000000FF,0,0,0,0,100,100,0,0,1,0,0,5,0,0,0,1

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,{\\blur10\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}

      """
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rotation-square-\(UUID().uuidString).ass")
    try script.write(to: url, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// Where any red shows, faint blurred edges included; nil when none does.
  private func redBounds(_ image: CGImage) throws -> CGRect? {
    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<image.height {
      for x in 0..<image.width {
        let index = y * image.bytesPerRow + x * 4
        // BGRA: red over black or white, never grey.
        let red = Int(bytes[index + 2]), green = Int(bytes[index + 1]), blue = Int(bytes[index])
        guard red - max(green, blue) > 24 else { continue }
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
      }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  private func subtitledSnapshot(of name: String) async throws -> CGImage {
    let session = try await session(for: name)
    let track = try await session.addExternalSubtitle(UmbelFileSource(url: try squareScript()))
    try await session.selectSubtitleTrack(track.id)
    try await showFirstPicture(session)
    return try await session.snapshot()
  }

  /// A turned picture is, subtitles and all, what the same picture stored
  /// upright is: libass is told the video's resolution as shown.
  func testSubtitlesOverATurnedPictureMatchThePictureStoredThatWay() async throws {
    let turned = try await subtitledSnapshot(of: "rotation_cw90.mp4")
    let stored = try await subtitledSnapshot(of: "rotation_portrait.mp4")
    XCTAssertEqual(turned.width, stored.width)
    XCTAssertEqual(turned.height, stored.height)
    let turnedBox = try XCTUnwrap(try redBounds(turned), "no square over the turned picture")
    let storedBox = try XCTUnwrap(try redBounds(stored), "no square over the upright one")
    XCTAssertEqual(turnedBox.minX, storedBox.minX, accuracy: 1, "\(turnedBox) against \(storedBox)")
    XCTAssertEqual(turnedBox.minY, storedBox.minY, accuracy: 1, "\(turnedBox) against \(storedBox)")
    XCTAssertEqual(turnedBox.width, storedBox.width, accuracy: 1, "\(turnedBox) against \(storedBox)")
    XCTAssertEqual(turnedBox.height, storedBox.height, accuracy: 1, "\(turnedBox) against \(storedBox)")
  }

  func testATimelinePreviewIsTurnedAndFitsItsBox() async throws {
    let url = fixture("rotation_cw90.mp4")
    let generator = UmbelThumbnailGenerator { try UmbelFileSource(url: url) }
    let preview = try await generator.thumbnail(at: .zero)
    XCTAssertEqual(preview.image.width, 64, "no upscaling past the shown size")
    XCTAssertEqual(preview.image.height, 128)
    XCTAssertGreaterThan(try green(preview.image, 48, 32), 200, "top-right is bright")
    XCTAssertLessThan(try green(preview.image, 16, 32), 60)

    let small = try await generator.thumbnail(at: .zero, maximumSize: CGSize(width: 32, height: 32))
    XCTAssertEqual(small.image.width, 16)
    XCTAssertEqual(small.image.height, 32)
  }
}
