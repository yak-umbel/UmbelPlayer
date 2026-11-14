import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import UmbelCore

/// Frames in, pictures out: each interlaced frame two progressive pictures
/// half a frame apart; everything else untouched.
final class VideoDeinterlacerTests: XCTestCase {
  private typealias Buffers = InterlaceTestBuffers
  private let bright: Float = 200.0 / 255, dark: Float = 40.0 / 255
  private let color = VideoColorDescription(matrix: .bt601, range: .limited)

  private func deinterlacer(
    _ setting: DeinterlaceSwitch = DeinterlaceSwitch(), nominalFrameRate: Double? = 25
  ) throws -> VideoDeinterlacer {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device here") }
    return VideoDeinterlacer(setting: setting, nominalFrameRate: nominalFrameRate)
  }

  /// The bar at x 20 on the even rows, at x 40 on the odd ones.
  private func wovenBar() -> CVPixelBuffer {
    Buffers.make(width: 64, height: 32) { x, y in
      let start = y % 2 == 0 ? 20 : 40
      return (start..<(start + 12)).contains(x) ? self.bright : self.dark
    }
  }

  private func stillLines() -> CVPixelBuffer {
    Buffers.make(width: 64, height: 32) { _, y in y % 2 == 0 ? self.bright : self.dark }
  }

  private func frame(
    _ buffer: CVPixelBuffer, at seconds: Double = 1, time: CMTime? = nil, order: FieldOrder? = .topFirst,
    duration: CMTime = CMTime(value: 1, timescale: 25), declaredFrameRate: Double? = nil
  ) -> VideoFrame {
    var frame = VideoFrame(
      presentationTime: time ?? CMTime(value: Int64((seconds * 90_000).rounded()), timescale: 90_000), pixelBuffer: buffer,
      width: 64, height: 32, color: color)
    frame.fieldOrder = order
    frame.duration = duration
    frame.declaredFrameRate = declaredFrameRate
    return frame
  }

  private func isBright(_ picture: VideoFrame, column x: Int) -> Bool {
    (0..<32).allSatisfy { Buffers.luma(picture.pixelBuffer!, x: x, y: $0) > 0.6 }
  }

  func testAnInterlacedFrameBecomesTwoPicturesHalfAFrameApart() throws {
    let input = frame(wovenBar())
    let pictures = try deinterlacer().process([input])
    XCTAssertEqual(pictures.count, 2)
    XCTAssertEqual(pictures[0].presentationTime.seconds, 1, accuracy: 1e-6)
    XCTAssertEqual(pictures[1].presentationTime.seconds, 1.02, accuracy: 1e-6)
    for picture in pictures {
      XCTAssertNil(picture.fieldOrder, "progressive now")
      XCTAssertFalse(picture.pixelBuffer === input.pixelBuffer)
    }
    XCTAssertTrue(isBright(pictures[0], column: 25), "the top field first")
    XCTAssertTrue(isBright(pictures[1], column: 45), "then the bottom field")
  }

  func testBottomFirstShowsTheBottomFieldFirst() throws {
    let pictures = try deinterlacer().process([frame(wovenBar(), order: .bottomFirst)])
    XCTAssertTrue(isBright(pictures[0], column: 45))
    XCTAssertTrue(isBright(pictures[1], column: 25))
  }

  /// Field-coded and frame-coded pictures can follow one another: each is
  /// decided on its own.
  func testProgressiveFramesPassUntouchedBetweenInterlacedOnes() throws {
    let progressive = frame(stillLines(), at: 1.04, order: nil)
    let pictures = try deinterlacer().process([frame(wovenBar(), at: 1), progressive, frame(wovenBar(), at: 1.08)])
    XCTAssertEqual(pictures.count, 5)
    XCTAssertTrue(pictures[2].pixelBuffer === progressive.pixelBuffer)
    let times = pictures.map { $0.presentationTime.seconds }
    for (time, expected) in zip(times, [1, 1.02, 1.04, 1.08, 1.10]) {
      XCTAssertEqual(time, expected, accuracy: 1e-6)
    }
  }

  func testOffPassesInterlacedFramesUntouched() throws {
    let input = frame(wovenBar())
    let pictures = try deinterlacer(DeinterlaceSwitch(.off)).process([input])
    XCTAssertEqual(pictures.count, 1)
    XCTAssertTrue(pictures[0].pixelBuffer === input.pixelBuffer)
  }

  func testWithoutADurationTheNominalRateSetsTheStep() throws {
    let pictures = try deinterlacer(nominalFrameRate: 50).process([frame(wovenBar(), duration: .invalid)])
    XCTAssertEqual(pictures.count, 2)
    XCTAssertEqual(pictures[1].presentationTime.seconds, 1.01, accuracy: 1e-6)
  }

  /// Two field pictures paired into one frame: its duration is one field's,
  /// 0.02 s, and the stream declares 25 frames a second. The pictures are
  /// 0.02 s apart — an even cadence — not 0.01 s.
  func testAFrameOfPairedFieldPicturesIsSpacedEvenly() throws {
    var input = frame(wovenBar(), duration: CMTime(value: 1, timescale: 50))
    input.declaredFrameRate = 25
    let pictures = try deinterlacer().process([input])
    XCTAssertEqual(pictures.count, 2)
    XCTAssertEqual(pictures[1].presentationTime.seconds - pictures[0].presentationTime.seconds, 0.02, accuracy: 1e-6)
  }

  func testWithNeitherOnlyTheFirstFieldShows() throws {
    let pictures = try deinterlacer(nominalFrameRate: nil).process([frame(wovenBar(), duration: .invalid)])
    XCTAssertEqual(pictures.count, 1)
    XCTAssertEqual(pictures[0].presentationTime.seconds, 1, accuracy: 1e-6)
    XCTAssertTrue(isBright(pictures[0], column: 25))
  }

  /// A second picture needs a time to come after; a frame with none shows
  /// its first field alone, at the time it has.
  func testAFrameWithNoValidTimeShowsOnlyItsFirstField() throws {
    for time in [CMTime.invalid, .indefinite] {
      let pictures = try deinterlacer().process([frame(wovenBar(), time: time)])
      XCTAssertEqual(pictures.count, 1, "\(time)")
      XCTAssertTrue(isBright(pictures[0], column: 25), "the top field")
    }
  }

  // MARK: - Nothing stated: the spacing of frames sets the step

  private func shownPictures(
    _ times: [Double], order: [FieldOrder?]? = nil, nominal: Double? = nil, duration: CMTime = .invalid,
    declared: Double? = nil
  ) throws -> [[VideoFrame]] {
    let deinterlacer = try deinterlacer(nominalFrameRate: nominal)
    let orders: [FieldOrder?] = order ?? Array(repeating: .topFirst, count: times.count)
    return times.enumerated().map { index, time in
      deinterlacer.process([
        frame(stillLines(), at: time, order: orders[index], duration: duration, declaredFrameRate: declared)])
    }
  }

  /// How far apart a frame's two pictures are; NaN when it has not two.
  private func halfFrame(_ pictures: [VideoFrame]) -> Double {
    guard pictures.count == 2 else { return .nan }
    return pictures[1].presentationTime.seconds - pictures[0].presentationTime.seconds
  }

  /// No duration, no declared rate, no nominal rate: the first two frames
  /// show their first field only; once two spacings agree, every frame shows
  /// two pictures, half a period apart.
  func testWithNothingStatedTheSpacingOfFramesSetsTheStep() throws {
    let pictures = try shownPictures([1.00, 1.04, 1.08, 1.12])
    XCTAssertEqual(pictures.map(\.count), [1, 1, 2, 2])
    let times = pictures[2].map { $0.presentationTime.seconds }
    for (time, expected) in zip(times, [1.08, 1.10]) { XCTAssertEqual(time, expected, accuracy: 1e-6) }
  }

  /// A seek forgets where the frames were, not how fast they come: the first
  /// frame after it already shows two pictures.
  func testASeekKeepsThePeriod() throws {
    let deinterlacer = try deinterlacer(nominalFrameRate: nil)
    for time in [1.00, 1.04, 1.08] { _ = deinterlacer.process([frame(stillLines(), at: time, duration: .invalid)]) }
    deinterlacer.reset()
    let after = deinterlacer.process([frame(stillLines(), at: 5.0, duration: .invalid)])
    XCTAssertEqual(after.count, 2)
    XCTAssertEqual(halfFrame(after), 0.02, accuracy: 1e-6)
    XCTAssertEqual(after.first?.presentationTime.seconds ?? .nan, 5.0, accuracy: 1e-6)
  }

  /// And it forgets the spacing across the seek: 41.5 ms after the last
  /// frame before it would agree with the 40 ms before that and nudge the
  /// period to 40.75 ms; forgotten, the step stays 20 ms.
  func testASeekForgetsTheSpacingAcrossIt() throws {
    let deinterlacer = try deinterlacer(nominalFrameRate: nil)
    for time in [1.00, 1.04, 1.08] { _ = deinterlacer.process([frame(stillLines(), at: time, duration: .invalid)]) }
    deinterlacer.reset()
    let after = deinterlacer.process([frame(stillLines(), at: 1.1215, duration: .invalid)])
    XCTAssertEqual(halfFrame(after), 0.02, accuracy: 0.0001)
  }

  /// A progressive frame between interlaced ones is a frame like any: leaving
  /// it out would make the spacing twice what it is.
  func testProgressiveFramesAreWatchedToo() throws {
    let pictures = try shownPictures([1.00, 1.04, 1.08], order: [.topFirst, nil, .topFirst])
    XCTAssertEqual(pictures.map(\.count), [1, 1, 2])
  }

  /// What the stream states is believed over what its frames' spacing says.
  func testWhatIsStatedWinsOverTheSpacing() throws {
    let stated = try shownPictures([1.00, 1.0333, 1.0667, 1.10], duration: CMTime(value: 1, timescale: 25))
    for pictures in stated { XCTAssertEqual(pictures.count, 2) }
    XCTAssertEqual(halfFrame(stated[3]), 0.02, accuracy: 1e-6)
    // A nominal rate of 50 says 10 ms, whatever the frames' spacing.
    let nominal = try shownPictures([1.00, 1.04, 1.08, 1.12], nominal: 50)
    XCTAssertEqual(halfFrame(nominal[3]), 0.01, accuracy: 1e-6)
  }

  /// A stream whose timing information holds the 27 MHz system clock where a
  /// frame rate belongs states nothing a frame can have: its frames' spacing
  /// sets the step, and the two pictures are not left at one time.
  func testAnAbsurdDeclaredRateLeavesItToTheSpacing() throws {
    let pictures = try shownPictures([1.00, 1.04, 1.08, 1.12], declared: 27_000_000)
    XCTAssertEqual(pictures.map(\.count), [1, 1, 2, 2])
    XCTAssertEqual(halfFrame(pictures[3]), 0.02, accuracy: 1e-6)
  }

  /// Frames that went by while switched off are not watched.
  func testFramesWhileOffAreNotWatched() throws {
    let setting = DeinterlaceSwitch(.off)
    let deinterlacer = try deinterlacer(setting, nominalFrameRate: nil)
    for time in [1.00, 1.04, 1.08] { _ = deinterlacer.process([frame(stillLines(), at: time, duration: .invalid)]) }
    setting.mode = .automatic
    XCTAssertEqual(deinterlacer.process([frame(stillLines(), at: 1.12, duration: .invalid)]).count, 1)
  }

  /// Still lines are woven back only with the frame before; after a reset —
  /// a seek — there is none, and the field alone fills in.
  func testResetForgetsTheFrameBefore() throws {
    let deinterlacer = try deinterlacer()
    _ = deinterlacer.process([frame(stillLines(), at: 1)])
    let woven = deinterlacer.process([frame(stillLines(), at: 1.04)])
    XCTAssertEqual(Buffers.luma(woven[0].pixelBuffer!, x: 30, y: 1), dark, accuracy: 1.0 / 255, "woven back")
    deinterlacer.reset()
    let alone = deinterlacer.process([frame(stillLines(), at: 1.08)])
    XCTAssertEqual(Buffers.luma(alone[0].pixelBuffer!, x: 30, y: 1), bright, accuracy: 1.0 / 255, "filled in")
  }

  /// Off, then on again: nothing from before it was turned off is used.
  func testTurningOffAndOnStartsAfresh() throws {
    let setting = DeinterlaceSwitch()
    let deinterlacer = try deinterlacer(setting)
    _ = deinterlacer.process([frame(stillLines(), at: 1)])
    setting.mode = .off
    _ = deinterlacer.process([frame(stillLines(), at: 1.04)])
    setting.mode = .automatic
    let after = deinterlacer.process([frame(stillLines(), at: 1.08)])
    XCTAssertEqual(Buffers.luma(after[0].pixelBuffer!, x: 30, y: 1), bright, accuracy: 1.0 / 255)
  }

  /// A kernel that cannot be made: frames go through as they are, every time.
  func testWithoutAKernelFramesPassThrough() {
    let failing = VideoDeinterlacer(setting: DeinterlaceSwitch(), nominalFrameRate: 25) {
      throw UmbelError.videoRenderUnavailable(reason: "none here")
    }
    for seconds in [1.0, 1.04] {
      let input = frame(wovenBar(), at: seconds)
      let pictures = failing.process([input])
      XCTAssertEqual(pictures.count, 1)
      XCTAssertTrue(pictures[0].pixelBuffer === input.pixelBuffer)
    }
  }

  /// A picture the kernel cannot make — a pixel format it has no pass for —
  /// lets the frame through woven, each time.
  func testAPassThatFailsLetsTheFrameThrough() throws {
    let unsupported = try bgraBuffer()
    for seconds in [1.0, 1.04] {
      let input = frame(unsupported, at: seconds)
      let pictures = try deinterlacer().process([input])
      XCTAssertEqual(pictures.count, 1)
      XCTAssertTrue(pictures[0].pixelBuffer === unsupported)
      XCTAssertEqual(pictures[0].presentationTime, input.presentationTime)
    }
  }

  /// A failure that repeats on every frame is noted once a second, with how
  /// many were left out since the last note, so it cannot fill the history.
  func testARepeatingFailureIsNotedOncePerSecond() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device here") }
    let diagnostics = UmbelPlaybackDiagnostics()
    var host = 100.0
    let deinterlacer = VideoDeinterlacer(
      setting: DeinterlaceSwitch(), nominalFrameRate: 25, diagnostics: diagnostics, hostSeconds: { host })
    let unsupported = try bgraBuffer()
    for time in [100.0, 100.4, 100.9, 101.2, 101.3] {
      host = time
      _ = deinterlacer.process([frame(unsupported, at: time)])
    }
    let notes = diagnostics.snapshot().events.filter { $0.name == "video_deinterlace_failed" }
    XCTAssertEqual(notes.count, 2)
    XCTAssertEqual(notes.map { $0.values["withheld"] }, [0, 2])
    XCTAssertNotNil(notes.first?.labels["reason"])
  }

  private func bgraBuffer() throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &made)
    return try XCTUnwrap(made)
  }
}
