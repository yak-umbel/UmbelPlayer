import CoreVideo
import Metal
import XCTest
@testable import UmbelCore

/// One progressive picture from an interlaced frame: still detail woven back
/// at full resolution, moving detail without combing.
final class DeinterlaceKernelTests: XCTestCase {
  private typealias Buffers = InterlaceTestBuffers
  private let bright: Float = 200.0 / 255, dark: Float = 40.0 / 255

  private func kernel() throws -> DeinterlaceKernel {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device here") }
    return try DeinterlaceKernel(device: device)
  }

  /// Fine horizontal lines: even rows bright, odd rows dark.
  private func stillLines(_ format: OSType = InterlaceTestBuffers.eightBit) -> CVPixelBuffer {
    Buffers.make(width: 64, height: 32, format: format) { _, y in y % 2 == 0 ? self.bright : self.dark }
  }

  /// A vertical bar: at `top` on the even rows, at `bottom` on the odd rows —
  /// a moving bar woven from two fields.
  private func bar(top: Int, bottom: Int, format: OSType = InterlaceTestBuffers.eightBit) -> CVPixelBuffer {
    Buffers.make(width: 64, height: 32, format: format) { x, y in
      let start = y % 2 == 0 ? top : bottom
      return (start..<(start + 12)).contains(x) ? self.bright : self.dark
    }
  }

  private func assertColumn(
    _ buffer: CVPixelBuffer, _ x: Int, isBright: Bool, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for y in 0..<32 {
      let value = Buffers.luma(buffer, x: x, y: y)
      if isBright { XCTAssertGreaterThan(value, 0.6, "\(message) row \(y)", file: file, line: line) }
      else { XCTAssertLessThan(value, 0.3, "\(message) row \(y)", file: file, line: line) }
    }
  }

  func testStillFineLinesAreWovenBackExactly() throws {
    let kernel = try kernel()
    let lines = stillLines()
    for (field, isFirst) in [(VideoField.top, true), (.bottom, false)] {
      let picture = try kernel.picture(from: lines, previous: stillLines(), keeping: field, isFirst: isFirst)
      for y in 0..<32 {
        for x in stride(from: 0, to: 64, by: 7) {
          XCTAssertEqual(Buffers.luma(picture, x: x, y: y), Buffers.luma(lines, x: x, y: y), accuracy: 0.5 / 255,
                         "\(field) (\(x), \(y))")
        }
      }
    }
  }

  func testAMovingBarLeavesNoComb() throws {
    let kernel = try kernel()
    let before = Buffers.make(width: 64, height: 32) { x, _ in (4..<16).contains(x) ? self.bright : self.dark }
    let woven = bar(top: 20, bottom: 40)
    XCTAssertGreaterThan(Buffers.combShare(woven), 0.05, "the input is combed")
    let first = try kernel.picture(from: woven, previous: before, keeping: .top, isFirst: true)
    XCTAssertLessThan(Buffers.combShare(first), 0.005)
    assertColumn(first, 25, isBright: true, "the top field's bar")
    assertColumn(first, 45, isBright: false, "no trace of the bottom field's bar")
    let second = try kernel.picture(from: woven, previous: before, keeping: .bottom, isFirst: false)
    XCTAssertLessThan(Buffers.combShare(second), 0.005)
    assertColumn(second, 45, isBright: true, "the bottom field's bar")
    assertColumn(second, 25, isBright: false, "no trace of the top field's bar")
  }

  /// A slanted edge, one pixel further right on every row, moving. The
  /// missing row's value is found along the edge — sharp — where an average
  /// of the rows above and below would be grey, and weaving the frame before
  /// in would be wrong: the edge was elsewhere.
  func testAMovingSlantedEdgeStaysSharpAlongItsDirection() throws {
    let kernel = try kernel()
    let edge: (Int, Int) -> Float = { x, y in x >= 20 + y ? self.bright : self.dark }
    let woven = Buffers.make(width: 64, height: 32, luma: edge)
    // The frame before: the same edge, ten pixels to the left.
    let before = Buffers.make(width: 64, height: 32) { x, y in x >= 10 + y ? self.bright : self.dark }
    let picture = try kernel.picture(from: woven, previous: before, keeping: .top, isFirst: true)
    for y in stride(from: 1, to: 31, by: 2) {
      let wanted = edge(20 + y, y)
      XCTAssertEqual(Buffers.luma(picture, x: 20 + y, y: y), wanted, accuracy: 0.02, "on the edge, row \(y)")
      XCTAssertEqual(Buffers.luma(picture, x: 19 + y, y: y), dark, accuracy: 0.02, "left of the edge, row \(y)")
    }
  }

  /// Between still and moving the two results are mixed, not switched. The
  /// frame before is 15/255 darker where the kept rows are, which is in the
  /// middle of the band: halfway between the woven value and the filled-in one.
  func testBetweenStillAndMovingTheTwoAreMixed() throws {
    let kept: Float = 0.5, missing: Float = 0.8, shift: Float = 15.0 / 255
    let woven = Buffers.make(width: 32, height: 16) { _, y in y % 2 == 0 ? kept : missing }
    let before = Buffers.make(width: 32, height: 16) { _, y in y % 2 == 0 ? kept - shift : missing }
    // The later field keeps the frame's own other field to weave: the value 0.8.
    let picture = try kernel().picture(from: woven, previous: before, keeping: .top, isFirst: false)
    let weight: Float = 0.5   // smoothstep of the middle of the band
    let mixed = (1 - weight) * missing + weight * kept
    for y in stride(from: 3, to: 13, by: 2) {
      XCTAssertEqual(Buffers.luma(picture, x: 16, y: y), mixed, accuracy: 0.02, "row \(y)")
    }
  }

  /// Where the picture is still, the earlier field's missing rows lie
  /// halfway between the frame before and this one — each half a frame away
  /// — and the later field's are this frame's own. The frame before differs
  /// by 5/255 there, inside the still band.
  func testTheEarlierFieldWeavesHalfwayToTheFrameBefore() throws {
    let kept: Float = 128.0 / 255, missing: Float = 204.0 / 255, earlier: Float = 199.0 / 255
    let woven = Buffers.make(width: 32, height: 16) { _, y in y % 2 == 0 ? kept : missing }
    let before = Buffers.make(width: 32, height: 16) { _, y in y % 2 == 0 ? kept : earlier }
    let kernel = try kernel()
    let first = try kernel.picture(from: woven, previous: before, keeping: .top, isFirst: true)
    let second = try kernel.picture(from: woven, previous: before, keeping: .top, isFirst: false)
    for y in stride(from: 3, to: 13, by: 2) {
      XCTAssertEqual(Buffers.luma(first, x: 16, y: y), (missing + earlier) / 2, accuracy: 0.6 / 255, "row \(y)")
      XCTAssertEqual(Buffers.luma(second, x: 16, y: y), missing, accuracy: 0.6 / 255, "row \(y)")
    }
  }

  func testTheKeptRowsAreUntouched() throws {
    let kernel = try kernel()
    let woven = bar(top: 20, bottom: 40)
    let picture = try kernel.picture(from: woven, previous: nil, keeping: .bottom, isFirst: true)
    for y in stride(from: 1, to: 32, by: 2) {
      for x in 0..<64 {
        XCTAssertEqual(Buffers.luma(picture, x: x, y: y), Buffers.luma(woven, x: x, y: y), accuracy: 0.5 / 255)
      }
    }
  }

  /// With no frame before, nothing tells still from moving: the missing rows
  /// come from the kept field alone, and fine lines are lost — never combed.
  func testWithoutAFrameBeforeTheFieldAloneFillsIn() throws {
    let picture = try kernel().picture(from: stillLines(), previous: nil, keeping: .top, isFirst: true)
    for y in 0..<32 { XCTAssertEqual(Buffers.luma(picture, x: 30, y: y), bright, accuracy: 1.0 / 255) }
  }

  /// A frame before of another size — a run encoded otherwise — is ignored.
  func testAFrameBeforeOfAnotherSizeIsIgnored() throws {
    let small = Buffers.make(width: 32, height: 16) { _, _ in self.dark }
    let picture = try kernel().picture(from: stillLines(), previous: small, keeping: .top, isFirst: true)
    for y in 0..<32 { XCTAssertEqual(Buffers.luma(picture, x: 30, y: y), bright, accuracy: 1.0 / 255) }
  }

  func testChromaMovesWithTheBar() throws {
    let red: (Float, Float) = (0.35, 0.9), grey: (Float, Float) = (0.5, 0.5)
    let before = Buffers.make(width: 64, height: 32, luma: { _, _ in 0.5 }) { x, _ in (2..<8).contains(x) ? red : grey }
    let woven = Buffers.make(width: 64, height: 32, luma: { _, _ in 0.5 }) { x, y in
      let start = y % 2 == 0 ? 10 : 20
      return (start..<(start + 6)).contains(x) ? red : grey
    }
    let picture = try kernel().picture(from: woven, previous: before, keeping: .top, isFirst: true)
    for y in 0..<16 {
      XCTAssertEqual(Buffers.chroma(picture, x: 12, y: y).1, 0.9, accuracy: 0.05, "top field's colour, row \(y)")
      XCTAssertEqual(Buffers.chroma(picture, x: 22, y: y).1, 0.5, accuracy: 0.05, "no bottom field's colour, row \(y)")
    }
  }

  func testTenBitBehavesAsEightBit() throws {
    let kernel = try kernel()
    let lines = stillLines(InterlaceTestBuffers.tenBit)
    let woven = try kernel.picture(from: lines, previous: stillLines(InterlaceTestBuffers.tenBit), keeping: .top, isFirst: true)
    for y in 0..<32 {
      XCTAssertEqual(Buffers.luma(woven, x: 30, y: y), Buffers.luma(lines, x: 30, y: y), accuracy: 1.0 / 1023)
    }
    let before = Buffers.make(width: 64, height: 32, format: InterlaceTestBuffers.tenBit) { x, _ in
      (4..<16).contains(x) ? self.bright : self.dark
    }
    let moving = try kernel.picture(
      from: bar(top: 20, bottom: 40, format: InterlaceTestBuffers.tenBit), previous: before, keeping: .top, isFirst: true)
    XCTAssertLessThan(Buffers.combShare(moving), 0.005)
    assertColumn(moving, 45, isBright: false, "no trace of the bottom field's bar")
  }

  func testThePictureIsANewBufferOfTheSameKind() throws {
    let lines = stillLines()
    let picture = try kernel().picture(from: lines, previous: nil, keeping: .top, isFirst: true)
    XCTAssertFalse(picture === lines)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(picture), CVPixelBufferGetPixelFormatType(lines))
    XCTAssertEqual(CVPixelBufferGetWidth(picture), 64)
    XCTAssertEqual(CVPixelBufferGetHeight(picture), 32)
  }
}
