import CoreMedia
import Foundation

/// Whether each routed track has handed its output a first frame since
/// playback started or last seeked; the clock waits until they all have.
///
/// Every stream is waited for before playing. Started as soon as enough was
/// buffered, the clock ran on while video was still decoding up to the
/// target, and after every seek the first pictures came late — dropped, and
/// out of step with the sound for a moment.
///
/// A track that ends counts as ready. So does one that has decoded two
/// seconds past where playback starts without handing anything on: a stream
/// that yields nothing must not hold the sound back for good.
internal struct FirstFrameWait: Sendable {
  internal static let giveUpAfter = 2.0

  private var awaited: Set<UmbelTrack.ID> = []
  /// Tracks that have handed a frame on since playback started.
  private var handedOn: Set<UmbelTrack.ID> = []
  private var origin = 0.0

  /// Nothing to wait for.
  internal init() {}

  /// Waits for `tracks`, playback starting at `origin`.
  internal init(awaiting tracks: Set<UmbelTrack.ID>, from origin: CMTime) {
    awaited = tracks
    self.origin = origin.isNumeric ? origin.seconds : 0
  }

  internal var isReady: Bool { awaited.isEmpty }

  /// `packet` was decoded, and `frames` of what came out were handed on.
  /// Returns whether this made the wait over.
  internal mutating func decoded(_ packet: DemuxPacket, handingOn frames: Int) -> Bool {
    guard awaited.contains(packet.trackID) else { return false }
    let time = packet.presentationTime
    let longPast = time.isNumeric && time.seconds > origin + Self.giveUpAfter
    guard frames > 0 || longPast else { return false }
    return release(packet.trackID)
  }

  /// Whether `frames` handed on from `track` include its first since
  /// playback started. Counted whether or not the track is still waited
  /// for: one given up on can still be the only output with a picture or a
  /// sound to go on with; see `BytePressureRelief`.
  internal mutating func firstFrame(from track: UmbelTrack.ID, handingOn frames: Int) -> Bool {
    frames > 0 && handedOn.insert(track).inserted
  }

  /// `track` has handed on all it ever will.
  internal mutating func finished(_ track: UmbelTrack.ID) -> Bool {
    release(track)
  }

  /// Only `routed` tracks are waited for: one switched off, or for another,
  /// has nothing more to hand on.
  internal mutating func keep(only routed: Set<UmbelTrack.ID>) -> Bool {
    handedOn.formIntersection(routed)
    let dropped = awaited.subtracting(routed)
    guard !dropped.isEmpty else { return false }
    awaited.subtract(dropped)
    return awaited.isEmpty
  }

  private mutating func release(_ track: UmbelTrack.ID) -> Bool {
    guard awaited.remove(track) != nil else { return false }
    return awaited.isEmpty
  }
}
