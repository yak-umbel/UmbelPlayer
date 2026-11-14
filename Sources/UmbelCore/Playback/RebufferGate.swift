import Foundation

/// Whether playback is held back waiting for data, with hysteresis.
///
/// It enters below the low watermark and leaves only above a higher level,
/// so it cannot flap on one boundary. That higher level depends on why it is
/// holding. Starting — at the beginning, or after a seek emptied the cache —
/// needs the start threshold. Recovering from running dry needs the larger
/// resume threshold: resuming at the start threshold on a link that just
/// failed to keep up makes playback stutter in short bursts.
internal struct RebufferGate: Sendable {
    internal private(set) var isHolding = true
    /// Holding because the cache ran dry, not because playback is starting.
    private var isRecovering = false

    /// Returns whether the state changed.
    internal mutating func update(
        isStarving: Bool, hasEnoughToStart: Bool, hasEnoughToResume: Bool
    ) -> Bool {
        if isHolding, isRecovering ? hasEnoughToResume : hasEnoughToStart {
            isHolding = false
            isRecovering = false
            return true
        }
        if !isHolding, isStarving {
            isHolding = true
            isRecovering = true
            return true
        }
        return false
    }

    /// The cache was emptied on purpose — a seek. A new start, not a stall.
    internal mutating func hold() {
        isHolding = true
        isRecovering = false
    }
}
