import FFmpeg
import XCTest
@testable import UmbelFFmpegSupport

/// A source that is gone, and how often it is asked.
private actor GoneSource {
  struct Gone: Error, Equatable {}
  private(set) var asked = 0

  func read() throws -> Data {
    asked += 1
    throw Gone()
  }
}

/// The context FFmpeg reads through, and a thread to read on: the callbacks
/// block, so they are not run on the cooperative pool.
private final class Reading: @unchecked Sendable {
  let context: FFmpegIOContext
  let thread = SerialWorkerThread(name: "io-failure-test")

  init(over source: GoneSource) throws {
    context = try FFmpegIOContext(
      callbacks: FFmpegIOCallbacks(
        read: { _ in try await source.read() },
        seek: { _ in },
        totalLength: { nil },
        canSeek: true),
      bufferSize: 4096)
  }

  /// What `avio_read` gives for 64 bytes, then whether FFmpeg thinks the end
  /// was reached — which it finds out by reading again, if it can.
  func readThenAskForTheEnd() async throws -> (read: Int32, atEnd: Int32) {
    try await thread.run { [self] in
      var bytes = [UInt8](repeating: 0, count: 64)
      let read = avio_read(context.rawPointer, &bytes, 64)
      return (read, avio_feof(context.rawPointer))
    }
  }

  func finish() {
    thread.shutdown()
    context.release()
  }
}

/// A source that fails is asked once. FFmpeg asks whether the end of the
/// input was reached after a read fails, and finds out by clearing the end
/// and reading again; a demuxer that checks, as MP4's does before it tries a
/// sample again, thereby asks the source a second time — useless for a source
/// that has failed for good, and a second wait for one that waited for the
/// network to come back before it gave up.
final class FFmpegIOFailureTests: XCTestCase {
  func testAskingForTheEndAfterAFailureDoesNotAskTheSourceAgain() async throws {
    let source = GoneSource()
    let reading = try Reading(over: source)
    defer { reading.finish() }

    let result = try await reading.readThenAskForTheEnd()

    XCTAssertLessThan(result.read, 0, "the read failed")
    let asked = await source.asked
    XCTAssertEqual(asked, 1, "the source was asked again after it had failed")
  }

  func testTheFailureIsTheSourcesOwn() async throws {
    let source = GoneSource()
    let reading = try Reading(over: source)
    defer { reading.finish() }

    _ = try await reading.readThenAskForTheEnd()

    XCTAssertEqual(reading.context.takePendingFailure() as? GoneSource.Gone, GoneSource.Gone())
  }

  /// Once the failure has been told, the next read is the source's to answer.
  func testAfterTheFailureIsToldTheSourceIsAskedAgain() async throws {
    let source = GoneSource()
    let reading = try Reading(over: source)
    defer { reading.finish() }

    _ = try await reading.readThenAskForTheEnd()
    _ = reading.context.takePendingFailure()
    _ = try await reading.thread.run { [reading] in
      // What a seek does: a fresh attempt.
      reading.context.rawPointer?.pointee.error = 0
      reading.context.rawPointer?.pointee.eof_reached = 0
      var bytes = [UInt8](repeating: 0, count: 64)
      return avio_read(reading.context.rawPointer, &bytes, 64)
    }

    let asked = await source.asked
    XCTAssertEqual(asked, 2, "a read after the failure was told reaches the source")
  }
}
