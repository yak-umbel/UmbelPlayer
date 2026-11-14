import CoreMedia
import XCTest
@testable import UmbelCore

/// The second field of an interlaced frame shows half the frame's duration
/// after the first.
final class FieldTimingTests: XCTestCase {
  func testHalfTheFramesDuration() throws {
    let step = try XCTUnwrap(FieldTiming.step(duration: CMTime(value: 1, timescale: 25), nominalFrameRate: 30))
    XCTAssertEqual(step.seconds, 0.02, accuracy: 1e-9, "the frame's own duration wins")
  }

  func testTheNominalRateWhenTheFrameHasNoDuration() throws {
    for unknown in [CMTime.invalid, .zero, CMTime(value: -1, timescale: 25)] {
      let step = try XCTUnwrap(FieldTiming.step(duration: unknown, nominalFrameRate: 25))
      XCTAssertEqual(step.seconds, 0.02, accuracy: 1e-9)
    }
  }

  /// A frame of two field pictures takes its duration from the first field's
  /// packet: one field long, 0.02 s of a 25-frame-a-second stream. The
  /// declared frame rate shows the duration is a field's, and the second
  /// field then comes a whole duration after the first, not half of one.
  func testAFrameDurationOfOneFieldIsTakenForOne() throws {
    let step = try XCTUnwrap(FieldTiming.step(
      duration: CMTime(value: 1, timescale: 50), declaredFrameRate: 25, nominalFrameRate: 50))
    XCTAssertEqual(step.seconds, 0.02, accuracy: 1e-9)
  }

  func testADeclaredRateThatAgreesWithTheDurationChangesNothing() throws {
    let step = try XCTUnwrap(FieldTiming.step(
      duration: CMTime(value: 1, timescale: 25), declaredFrameRate: 25, nominalFrameRate: 25))
    XCTAssertEqual(step.seconds, 0.02, accuracy: 1e-9)
  }

  /// A declared rate that fits neither reading of the duration — one field's,
  /// or a whole frame's — is not believed: the frame's own duration, halved.
  func testADeclaredRateThatAgreesWithNeitherReadingIsIgnored() throws {
    let step = try XCTUnwrap(FieldTiming.step(
      duration: CMTime(value: 1, timescale: 25), declaredFrameRate: 30, nominalFrameRate: 25))
    XCTAssertEqual(step.seconds, 0.02, accuracy: 1e-9, "half the frame's own duration")
  }

  func testTheDeclaredRateBeforeTheNominalOneWhenThereIsNoDuration() throws {
    let step = try XCTUnwrap(FieldTiming.step(duration: .invalid, declaredFrameRate: 25, nominalFrameRate: 50))
    XCTAssertEqual(step.seconds, 0.02, accuracy: 1e-9)
  }

  /// Some streams write the system clock where a frame rate belongs: 27 MHz.
  /// A step of nothing at all is no step; such a rate counts as not stated,
  /// whichever of the two sources it comes from.
  func testARateNoFrameCanHaveIsNotBelieved() throws {
    let nominal = try XCTUnwrap(FieldTiming.step(duration: .invalid, declaredFrameRate: 27_000_000, nominalFrameRate: 25))
    XCTAssertEqual(nominal.seconds, 0.02, accuracy: 1e-9, "the declared one skipped, the nominal one used")
    XCTAssertNil(FieldTiming.step(duration: .invalid, declaredFrameRate: 27_000_000, nominalFrameRate: nil))
    XCTAssertNil(FieldTiming.step(duration: .invalid, declaredFrameRate: nil, nominalFrameRate: 27_000_000))
    XCTAssertNil(FieldTiming.step(duration: .invalid, declaredFrameRate: 90_000, nominalFrameRate: 1_000))
    XCTAssertNil(FieldTiming.step(duration: .invalid, declaredFrameRate: 5, nominalFrameRate: 0.5), "slower than 10 a second")
  }

  /// The range is that of a frame period: from 10 to 62.5 frames a second.
  func testTheRatesAtTheEdgesOfTheRangeAreBelieved() throws {
    let slow = try XCTUnwrap(FieldTiming.step(duration: .invalid, nominalFrameRate: 10))
    XCTAssertEqual(slow.seconds, 0.05, accuracy: 1e-9)
    let fast = try XCTUnwrap(FieldTiming.step(duration: .invalid, nominalFrameRate: 60))
    XCTAssertEqual(fast.seconds, 1.0 / 120, accuracy: 1e-6)
  }

  func testNothingWhenNeitherIsKnown() {
    XCTAssertNil(FieldTiming.step(duration: .invalid, nominalFrameRate: nil))
    XCTAssertNil(FieldTiming.step(duration: .invalid, nominalFrameRate: 0))
    XCTAssertNil(FieldTiming.step(duration: .invalid, nominalFrameRate: .nan))
  }
}
