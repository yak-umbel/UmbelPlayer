import AVFoundation
import CoreMedia
import Foundation

/// A system timeline that can hand its part to another for a while: the
/// render synchronizer normally, the system player's clock while that plays
/// the sound (object audio).
///
/// Display layers put on it follow whichever is in charge, and a switch
/// moves them. The sound renderer stays on the synchronizer, the only clock
/// it can follow; it is given nothing while the player plays. The timeline
/// taking over starts where the other stood, at its rate, and the other
/// stops there.
internal final class SwitchableTimeline: SystemTimeline, @unchecked Sendable {
  private let base: any SystemTimeline
  private let lock = NSLock()
  // Guarded by `lock`, touched only in the synchronous helpers below.
  private var standIn: (any SystemTimeline)?
  private var pictures: [QueuedRenderer] = []
  private var rate: Double = 0
  private var handover: Task<Void, Never>?

  init(base: any SystemTimeline) {
    self.base = base
  }

  var time: CMTime { inCharge().time }
  var handoverTime: CMTime { inCharge().handoverTime }

  func set(rate: Double, time: CMTime) {
    lock.withLock {
      self.rate = rate
      (standIn ?? base).set(rate: rate, time: time)
    }
  }

  func setRate(_ rate: Double) {
    lock.withLock {
      self.rate = rate
      (standIn ?? base).setRate(rate)
    }
  }

  func add(_ renderer: QueuedRenderer) throws {
    guard !(renderer.renderer is AVSampleBufferAudioRenderer) else { return try base.add(renderer) }
    let timeline = keep(renderer)
    try timeline.add(renderer)
  }

  func remove(_ renderer: QueuedRenderer) async {
    guard !(renderer.renderer is AVSampleBufferAudioRenderer) else { return await base.remove(renderer) }
    let timeline = forget(renderer)
    await timeline.remove(renderer)
  }

  /// `other` takes charge from here, where the current one stands.
  func hand(over other: any SystemTimeline) async {
    await enqueueSwitch(to: other).value
  }

  /// The synchronizer takes charge again, from where the stand-in stands.
  func takeBack() async {
    await enqueueSwitch(to: nil).value
  }

  /// Handover calls may overlap while renderer removal is suspended.
  private func enqueueSwitch(to next: (any SystemTimeline)?) -> Task<Void, Never> {
    lock.withLock {
      let previous = handover
      let operation = Task {
        await previous?.value
        await self.switchTo(next)
      }
      handover = operation
      return operation
    }
  }

  private func switchTo(_ next: (any SystemTimeline)?) async {
    let (current, moving) = snapshot()
    let incoming = next ?? base
    guard current !== incoming else { return }
    for renderer in moving {
      await current.remove(renderer)
      try? incoming.add(renderer)
    }
    lock.withLock {
      // Preserve an accepted seek even if the outgoing audio clock is still
      // waiting at its old position. Controls and this transfer are atomic.
      let now = current.handoverTime
      standIn = next
      current.set(rate: 0, time: now)
      incoming.set(rate: rate, time: now)
    }
  }

  // ── Guarded state ───────────────────────────────────

  private func inCharge() -> any SystemTimeline {
    lock.withLock { standIn ?? base }
  }

  private func keep(_ renderer: QueuedRenderer) -> any SystemTimeline {
    lock.withLock {
      pictures.append(renderer)
      return standIn ?? base
    }
  }

  private func forget(_ renderer: QueuedRenderer) -> any SystemTimeline {
    lock.withLock {
      pictures.removeAll { $0.renderer === renderer.renderer }
      return standIn ?? base
    }
  }

  private func snapshot() -> (any SystemTimeline, [QueuedRenderer]) {
    lock.withLock { (standIn ?? base, pictures) }
  }
}

extension SwitchableTimeline: PlaybackDiagnosticsReceiving {
  func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) async {
    await (base as? any PlaybackDiagnosticsReceiving)?.setPlaybackDiagnostics(diagnostics)
  }
}
