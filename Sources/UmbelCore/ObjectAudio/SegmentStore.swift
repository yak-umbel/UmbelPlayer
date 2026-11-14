import CoreMedia
import Foundation

/// The sound track's packets, gathered into the plan's segments as reading
/// brings them, for the system player to ask for by number.
///
/// Packets come in order, so a segment is complete once its last frame has
/// come, or a later segment's first, or the end. Asked for one not yet
/// complete, the asker waits: reading is behind, and the player with it.
///
/// Reading waits in turn when it gets more than `window` segments past the
/// furthest asked for or played, and segments more than `keepBehind` behind
/// that are let go, so what is held stays small whatever the player's
/// appetite. Where it plays counts: going back over what it played, it plays
/// from what it kept and asks for nothing, and reading let on only as it
/// asked never got to the end. A
/// seek starts again at a segment (`reset(to:)`); asking for one before it,
/// or one let go, fails — reading will not come back for it.
///
/// Waiting is looked at a hundred times a second rather than resumed from a
/// continuation: the waits are rare and short, and a cancelled one ends
/// by itself.
internal actor SegmentStore {
  enum Failure: Error, Equatable {
    /// Before where reading now starts, or let go since.
    case gone(Int)
    case closed
  }

  /// Packets the initialization segment is made from; see `leading()`.
  static let leadingCount = 4

  private let plan: SegmentPlan
  private let window: Int
  private let keepBehind: Int
  /// Where reading starts: at the first segment, or a seek's.
  private var base = 0
  /// Segments before this are complete, however many packets they have.
  private var completeBelow = 0
  /// Segments before this have been let go.
  private var keptFrom = 0
  private var ended = false
  private var closed = false
  private var segments: [Int: [DemuxPacket]] = [:]
  /// The furthest segment asked for since the last reset.
  private var furthestAsked = -1
  /// The furthest segment played since the last reset, as told.
  private var furthestPlayed = -1
  /// The furthest frame taken since the last reset.
  private var received: Int?
  /// When the packet taken last starts; one handed over again is not taken again.
  private var lastTime: CMTime?
  /// Whether frames have come one after the other since the last reset.
  private var cameInOrder = true
  /// The first segment of a seek that goes on with what is held, kept from
  /// being let go until the player is there.
  private var pinned: Int?
  /// The player was moved since the claim: only what it reports then counts.
  private var pinMoved = false
  /// Up by one on each reset: where the player was told to be before one
  /// says nothing of where it goes.
  private(set) var epoch = 0
  private var first: [DemuxPacket] = []
  private var waitingRequests = 0
  private var heldReads = 0

  init(plan: SegmentPlan, window: Int = 2, keepBehind: Int = 2) {
    self.plan = plan
    self.window = window
    self.keepBehind = keepBehind
  }

  /// A request waits for reading: the player is waiting on it.
  var isWaiting: Bool { waitingRequests > 0 }
  /// Reading waits for the player to ask for more.
  var isHoldingReading: Bool { heldReads > 0 }

  /// Takes a packet of the track, then waits while it is too far ahead of
  /// what the player has asked for. In first: reading stopped while it
  /// waits has taken the packet from the cache and nothing else has it.
  func append(_ packet: DemuxPacket) async throws {
    guard packet.presentationTime.isNumeric, plan.frame(of: packet.presentationTime) >= 0,
          packet.presentationTime != lastTime else { return }
    let frame = plan.frame(of: packet.presentationTime)
    let index = plan.index(of: packet.presentationTime)
    try check()
    lastTime = packet.presentationTime
    // One skipped leaves a hole in a segment; one gone back over doubles a frame.
    if let received, frame > received + 1 || frame < received { cameInOrder = false }
    received = max(received ?? frame, frame)
    if first.count < Self.leadingCount { first.append(packet) }
    // Before a seek's start, or late for a segment already complete.
    if index >= completeBelow {
      segments[index, default: []].append(packet)
      completeBelow = index
      let last = frame % plan.framesPerSegment == plan.framesPerSegment - 1
      // The last segment also takes what runs past the playlist's end.
      if last, index < plan.count - 1 { completeBelow = index + 1 }
    }
    guard index > reach else { return }
    heldReads += 1
    defer { heldReads -= 1 }
    while index > reach {
      try check()
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  /// How far reading is let on.
  private var reach: Int { max(furthestAsked, furthestPlayed, base) + window }

  /// The player is playing at `time`, in the film's time, as seen during
  /// `epoch`: reading is let on from there, and what is well behind let go.
  func playerIsAt(_ time: CMTime, epoch: Int) {
    guard epoch == self.epoch, time.isNumeric, plan.frame(of: time) >= 0 else { return }
    let index = plan.index(of: time)
    if let pinned, pinMoved, index >= pinned { self.pinned = nil }
    guard index > furthestPlayed else { return }
    furthestPlayed = index
    letGo(before: index - keepBehind)
  }

  /// The packets of segment `index`, once it is complete. None for one
  /// listed but never read.
  func packets(of index: Int) async throws -> [DemuxPacket] {
    waitingRequests += 1
    defer { waitingRequests -= 1 }
    while true {
      try check()
      guard index >= keptFrom else { throw Failure.gone(index) }
      furthestAsked = max(furthestAsked, index)
      if ended || index < completeBelow {
        letGo(before: index - keepBehind)
        return segments[index] ?? []
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  /// The track's first packets, from which the initialization segment's
  /// description of the stream is made; fewer only for a shorter track.
  func leading() async throws -> [DemuxPacket] {
    waitingRequests += 1
    defer { waitingRequests -= 1 }
    while first.count < Self.leadingCount, !ended {
      try check()
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    return first
  }

  /// Reading reached the end: what is left is complete.
  func finish() {
    ended = true
  }

  /// Reading starts again at segment `index`, after a seek.
  func reset(to index: Int) {
    segments = [:]
    base = index
    completeBelow = index
    keptFrom = index
    furthestAsked = index - 1
    furthestPlayed = index - 1
    received = nil
    lastTime = nil
    cameInOrder = true
    pinned = nil
    epoch += 1
    ended = false
  }

  /// Whether a seek whose player asks for segment `index` first can go on
  /// with what the store has, instead of starting again: that segment is
  /// held or still to come, and the packet reading brings next, starting at
  /// `next`, follows the last one taken — a packet lost between would leave
  /// a hole in a segment. Packets must also have come in order since the
  /// last reset, and `next` must be there: with none queued nothing says
  /// none was lost, nor where the sound ends. If so, the segment is kept
  /// from being let go, however requests already out are answered, until the
  /// player has been moved (`playerWasMoved()`) and reports being there.
  func keep(from index: Int, nextPacketAt next: CMTime?) -> Bool {
    guard !closed, cameInOrder, index >= keptFrom, let received, let next, next.isNumeric,
          plan.frame(of: next) <= received + 1 else { return false }
    pinned = index
    pinMoved = false
    return true
  }

  /// The player was moved to the seek's target: where it was told to be
  /// before says nothing of where it goes.
  func playerWasMoved() {
    epoch += 1
    pinMoved = true
  }

  func close() {
    closed = true
    segments = [:]
  }

  private func check() throws {
    if closed { throw Failure.closed }
    try Task.checkCancellation()
  }

  private func letGo(before limit: Int) {
    let index = min(limit, pinned ?? limit)
    guard index > keptFrom else { return }
    for key in segments.keys where key < index { segments[key] = nil }
    keptFrom = index
  }
}
