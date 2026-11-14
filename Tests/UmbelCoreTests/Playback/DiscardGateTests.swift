import CoreMedia
import XCTest
@testable import UmbelCore

final class DiscardGateTests: XCTestCase {
  private func time(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
  }

  /// Before a seek's target a frame is not shown, so its decoder need only
  /// produce what later frames refer to.
  func testFramesBeforeTheTargetAreHidden() {
    var gate = DiscardGate()
    XCTAssertFalse(gate.hidesVideo(at: time(1)), "no seek, nothing hidden")
    gate.armBoth(at: time(10))
    XCTAssertTrue(gate.hidesVideo(at: time(9.96)))
    XCTAssertFalse(gate.hidesVideo(at: time(10)))
    XCTAssertFalse(gate.hidesVideo(at: .invalid), "no time: shown, as the gate passes it")
  }

  /// A frame the system decodes itself, for the gate: only its time and
  /// whether it is shown matter here.
  private func compressed(at seconds: Double, shown: Bool) throws -> VideoFrame {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 16, height: 16,
      extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: 1, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: 1, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
    var size = 1
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReady(
      allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    return VideoFrame(
      presentationTime: time(seconds), compressed: try XCTUnwrap(sample), width: 16, height: 16,
      color: VideoColorDescription(matrix: .bt2020, range: .limited, transfer: .pq, primaries: .bt2020),
      isShown: shown)
  }

  /// The system decodes the frames before a seek's target for the ones after
  /// it: they go on, marked not to be shown, and do not end the wait.
  func testCompressedFramesBeforeTheTargetGoOnHidden() throws {
    var gate = DiscardGate()
    gate.armBoth(at: time(10))
    let early = try compressed(at: 9.5, shown: false)
    let passed = gate.videoFramesToDeliver([early])
    XCTAssertEqual(passed.count, 1)
    XCTAssertFalse(passed[0].isShown)
    XCTAssertTrue(gate.hidesVideo(at: time(9.9)), "the target is not reached yet")
  }

  /// Compressed frames come in decode order: one before the target can
  /// follow one after it, and still must not be shown.
  func testFramesBeforeTheTargetStayHiddenAfterOneBeyondIt() throws {
    var gate = DiscardGate()
    gate.armBoth(at: time(10))
    let passed = gate.videoFramesToDeliver([try compressed(at: 10.04, shown: true)])
    XCTAssertEqual(passed.count, 1)
    XCTAssertTrue(gate.hidesVideo(at: time(9.96)), "a B-frame before the target, after one beyond it")
    XCTAssertFalse(gate.hidesVideo(at: time(10.08)))
  }

  /// Decoded frames come in presentation order: past the target, none
  /// earlier follow, and the gate opens.
  func testDecodedFramesLiftTheThresholdAtTheTarget() {
    var gate = DiscardGate()
    gate.armBoth(at: time(10))
    let buffer = VideoFrame.makeTestPixelBuffer(width: 16, height: 16, luma: 126, cb: 128, cr: 128)!
    let frame = VideoFrame(
      presentationTime: time(10.04), pixelBuffer: buffer, width: 16, height: 16,
      color: VideoColorDescription(matrix: .bt709, range: .limited))
    _ = gate.videoFramesToDeliver([frame])
    XCTAssertFalse(gate.hidesVideo(at: time(9)))
  }

  func testNothingIsHiddenOnceTheTargetIsReached() {
    var gate = DiscardGate()
    gate.armBoth(at: time(10))
    _ = gate.videoFramesToDeliver([])
    XCTAssertTrue(gate.hidesVideo(at: time(9)))
    gate.armAudio(at: time(20))
    XCTAssertTrue(gate.hidesVideo(at: time(9)), "the audio threshold is its own")
  }
}
