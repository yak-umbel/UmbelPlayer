import Foundation

/// How playback came to an end, if it has: played out, or failed and why.
/// A read error is held back until what was read before it has played out.
internal struct PlaybackOutcome {
    private(set) var phase: UmbelPlaybackPhase?
    private(set) var failure: UmbelError?
    /// A read error waits for buffered playout.
    var readFailure: Error?

    var isSettled: Bool { phase != nil }

    mutating func fail(_ error: Error) {
        phase = .failed
        failure = UmbelError.wrapping(error)
    }

    /// Back to undecided, for playback going on after a seek or a restart.
    mutating func clear() {
        phase = nil
        failure = nil
    }

    /// Everything handed on has played out: ended, unless reading failed.
    mutating func playedOut() {
        if let readFailure {
            fail(readFailure)
        } else {
            phase = .ended
        }
    }
}
