import XCTest
@testable import UmbelCore

final class UmbelPlaybackPhaseTests: XCTestCase {
  func testTerminalPhases() {
    let terminal = UmbelPlaybackPhase.allCases.filter(\.isTerminal)
    XCTAssertEqual(Set(terminal), [.ended, .failed])
  }

  func testOnlyPlayingAdvances() {
    let advancing = UmbelPlaybackPhase.allCases.filter(\.isAdvancing)
    XCTAssertEqual(advancing, [.playing])
  }

  func testContentAvailabilityMatchesPhase() {
    XCTAssertFalse(UmbelPlaybackPhase.idle.hasOpenedContent)
    XCTAssertFalse(UmbelPlaybackPhase.opening.hasOpenedContent)
    XCTAssertFalse(UmbelPlaybackPhase.failed.hasOpenedContent)
    XCTAssertTrue(UmbelPlaybackPhase.buffering.hasOpenedContent)
    XCTAssertTrue(UmbelPlaybackPhase.ended.hasOpenedContent)
  }
}

final class UmbelErrorTests: XCTestCase {
  func testTransientFailuresAreRetryable() {
    XCTAssertTrue(UmbelError.sourceUnavailable(detail: "timeout").isRetryable)
    XCTAssertTrue(UmbelError.interrupted.isRetryable)
  }

  func testFormatFailuresAreNotRetryable() {
    XCTAssertFalse(UmbelError.unsupportedCodec("ac4").isRetryable)
    XCTAssertFalse(UmbelError.decoderFailure(codec: "hevc", code: -12909).isRetryable)
  }

  func testSeekUnsupportedIsNotRetryable() {
    XCTAssertFalse(UmbelError.seekUnsupported.isRetryable)
  }

  /// A system error carries the system's words, which follow the device's
  /// language; folded in, it is named by its domain and code alone.
  func testASystemErrorFoldsToItsDomainAndCode() {
    let system = NSError(domain: NSCocoaErrorDomain, code: 260,
                         userInfo: [NSLocalizedDescriptionKey: "无法打开文件"])
    XCTAssertEqual(UmbelError.wrapping(system),
                   .sourceUnavailable(detail: "NSCocoaErrorDomain error 260"))
  }

  private enum Unforeseen: Error { case broken(Int) }

  /// An error of Swift's own has no system words to drop, and its case says
  /// more than a code would.
  func testASwiftErrorFoldsToItsCase() {
    XCTAssertEqual(UmbelError.wrapping(Unforeseen.broken(3)),
                   .sourceUnavailable(detail: "broken(3)"))
  }
}
