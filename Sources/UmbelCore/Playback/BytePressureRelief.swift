import Foundation

/// What the cache measures, and what reading stopped at the packet byte
/// budget calls for (`BufferingConfiguration.maximumPacketBytes`).
///
/// Reading stops for every stream at once, so one stream's packets can keep
/// another's from being read at all, and then nothing moves:
///
/// - The outputs that have handed on a first frame since playback started
///   go on without the others (`relieve(soundReady:)`). The system player's
///   sound counts once its clock leads.
/// - When the track the level is measured by has none, one that has stands
///   in for it (`measurement`), until it hands one on (`firstFrame(of:)`),
///   or a route measures another track or belongs to another seek
///   generation. A subtitle switch changes neither.
/// - Sound for the system player that waits on reading is asked back, to be
///   decoded here (`askForFallback()`): one request at a time, standing only
///   while its route and seek generation do.
internal struct BytePressureRelief {
  /// A request that the system player give the sound back.
  internal struct FallbackRequest: Sendable {
    let route: ObjectAudioRoute
    let generation: Int
    let serial: Int
  }

  private(set) var routing = PacketRouting(
    audioID: nil, audioSession: nil, videoID: nil, videoSession: nil, generation: 0)
  /// Tracks whose outputs wait for a first frame.
  private var routed: Set<UmbelTrack.ID> = []
  private var revision = Int.min
  /// Routed tracks that have handed on a frame since playback started.
  private var framed: Set<UmbelTrack.ID> = []
  private var standIn: UmbelTrack.ID?
  private var pending: FallbackRequest?
  private var serial = 0

  /// Takes `routing`, published as `revision`, unless a later one came
  /// first; returns whether it did.
  mutating func route(_ routing: PacketRouting, routed: Set<UmbelTrack.ID>, revision: Int) -> Bool {
    guard revision >= self.revision else { return false }
    let previous = self.routing
    (self.routing, self.routed, self.revision) = (routing, routed, revision)
    framed.formIntersection(routed)
    let newGeneration = routing.generation != previous.generation
    if newGeneration || routing.objectAudio !== previous.objectAudio { pending = nil }
    if let track = standIn, newGeneration || routing.measuredTrack != previous.measuredTrack
      || !routing.selectedTracks.contains(track) {
      standIn = nil
    }
    return true
  }

  /// Playback starts again: no output has a first frame yet.
  mutating func restart() { framed = [] }

  /// `track` handed on its first frame since playback started. Returns
  /// whether the track the route measures by does so again.
  mutating func firstFrame(of track: UmbelTrack.ID) -> Bool {
    guard routed.contains(track) else { return false }
    framed.insert(track)
    guard standIn != nil, track == routing.measuredTrack else { return false }
    standIn = nil
    return true
  }

  /// What the cache measures by: the route's track, or the one standing in.
  var measurement: (track: UmbelTrack.ID?, gatesPlayback: Bool, takenOnDemand: UmbelTrack.ID?) {
    guard let standIn else {
      return (routing.measuredTrack, routing.levelGatesPlayback, routing.soundTakenOnDemand)
    }
    return (standIn, routing.objectAudio == nil, routing.soundTakenOnDemand)
  }

  /// At the budget, first frames still waited for: whether any output has
  /// one to go on with. The measured track has none if another stands in.
  mutating func relieve(soundReady: Bool) -> Bool {
    var ready = framed
    if soundReady, routing.objectAudio != nil, let sound = routing.audioID { ready.insert(sound) }
    guard !ready.isEmpty else { return false }
    if let measured = routing.measuredTrack, !ready.contains(measured) { standIn = ready.first }
    return true
  }

  /// Whether the system player plays sound beside a picture, with no
  /// request out for it yet.
  var mayAskForFallback: Bool { routing.videoID != nil && routing.objectAudio != nil && pending == nil }

  mutating func askForFallback() -> FallbackRequest? {
    guard mayAskForFallback, let route = routing.objectAudio else { return nil }
    serial += 1
    pending = FallbackRequest(route: route, generation: routing.generation, serial: serial)
    return pending
  }

  /// Whether `request` is still the one out, for the route and seek
  /// generation now current.
  func holds(_ request: FallbackRequest) -> Bool {
    pending?.serial == request.serial && routing.objectAudio === request.route
      && routing.generation == request.generation
  }

  /// `request` was answered; another may be made.
  mutating func settle(_ request: FallbackRequest) {
    if pending?.serial == request.serial { pending = nil }
  }
}
