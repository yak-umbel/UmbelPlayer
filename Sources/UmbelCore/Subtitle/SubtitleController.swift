import CoreGraphics
import CoreMedia
import Foundation

/// Owns independent subtitle layers and their shared external track catalog.
internal actor SubtitleController {
  internal typealias EmbeddedCueReader = @Sendable (SubtitleDecodeSession, CMTime) async -> [UmbelSubtitleCue]
  private let demux: DemuxSession
  private let readEmbeddedCues: EmbeddedCueReader
  private let primary = SubtitleSlotState()
  private let secondary = SubtitleSlotState(placement: .init(verticalOffset: 0.2))
  private var isAutomatic = true
  private var automaticGeneration = 0
  private var isClosed = false
  private var external: [UmbelTrack.ID: ExternalSubtitle] = [:]
  private var externalOrder: [UmbelTrack.ID] = []
  private var nextExternalID: Int32 = 1_000_000
  private var fonts: [EmbeddedFont] = []
  /// The fonts the host gave ASS tracks; each ASS source is made with them.
  internal private(set) var hostFonts = UmbelSubtitleFonts()
  /// What libass's drawings cost, over every source this controller makes.
  private let renderMeter = SubtitleRenderMeter()
  /// Selection/settings revisions also invalidate rendering suspended on a source actor.
  private var revision = 0
  private var renderedRevision = -1
  /// Only source/offset changes invalidate a seek's replay assumptions.
  /// Flushing decoders as part of that seek must not invalidate its own snapshot.
  internal private(set) var replayRevision = 0

  internal init(
    demux: DemuxSession,
    readEmbeddedCues: @escaping EmbeddedCueReader = { await $0.cues(at: $1) }
  ) {
    self.demux = demux
    self.readEmbeddedCues = readEmbeddedCues
  }

  private func state(for slot: UmbelSubtitleSlot) -> SubtitleSlotState {
    slot == .primary ? primary : secondary
  }

  internal var selectedTrack: UmbelTrack? { primary.track }
  internal var placement: UmbelSubtitlePlacement { primary.placement }
  internal func selectedTrack(for slot: UmbelSubtitleSlot) -> UmbelTrack? { state(for: slot).track }
  internal func delay(for slot: UmbelSubtitleSlot) -> TimeInterval { state(for: slot).delaySeconds }
  internal func scale(for slot: UmbelSubtitleSlot) -> Double { state(for: slot).scale }
  internal func placement(for slot: UmbelSubtitleSlot) -> UmbelSubtitlePlacement {
    state(for: slot).placement
  }

  internal func setDelay(_ seconds: TimeInterval, for slot: UmbelSubtitleSlot = .primary) {
    guard state(for: slot).delaySeconds != seconds else { return }
    state(for: slot).delaySeconds = seconds
    revision += 1
    if state(for: slot).decoder != nil {
      replayRevision += 1
      state(for: slot).replayRevision = replayRevision
    }
  }

  internal func setScale(_ scale: Double, for slot: UmbelSubtitleSlot = .primary) {
    state(for: slot).scale = scale
    revision += 1
  }

  @discardableResult
  internal func setPlacement(
    _ placement: UmbelSubtitlePlacement, for slot: UmbelSubtitleSlot = .primary
  ) -> Bool {
    let state = state(for: slot)
    guard placement != state.placement else { return false }
    state.placement = placement
    revision += 1
    return true
  }

  internal var externalTracks: [UmbelTrack] {
    externalOrder.compactMap { external[$0]?.track }
  }

  internal var embeddedSelections: [SubtitleRoute] {
    UmbelSubtitleSlot.allCases.compactMap { slot in
      let state = state(for: slot)
      guard let track = state.track, let decoder = state.decoder else { return nil }
      return SubtitleRoute(id: track.id, receiver: decoder)
    }
  }

  internal func selectManually(
    _ id: UmbelTrack.ID?, for slot: UmbelSubtitleSlot = .primary
  ) async throws {
    let wasAutomatic = isAutomatic
    if slot == .primary {
      automaticGeneration += 1
      isAutomatic = false
    }
    let generation = automaticGeneration
    do {
      try await show(id, for: slot)
    } catch {
      if slot == .primary, generation == automaticGeneration, !isClosed {
        isAutomatic = wasAutomatic
      }
      throw error
    }
  }

  internal func selectAutomatically(audio: UmbelTrack?) async throws {
    isAutomatic = true
    try await followAudio(audio)
  }

  internal func followAudio(_ audio: UmbelTrack?) async throws {
    guard isAutomatic, !isClosed else { return }
    automaticGeneration += 1
    let generation = automaticGeneration
    let tracks = await demux.tracks + externalTracks
    guard isAutomatic, generation == automaticGeneration, !isClosed else { return }
    try await show(SubtitleSelection.forcedTrack(for: audio, in: tracks)?.id, for: .primary)
  }

  /// Build first; commit only if this request still owns its slot.
  private func show(_ id: UmbelTrack.ID?, for slot: UmbelSubtitleSlot) async throws {
    guard !isClosed else { return }
    let state = state(for: slot)
    state.selectionGeneration += 1
    let generation = state.selectionGeneration
    guard id != state.track?.id else { return }
    var track: UmbelTrack?
    var session: SubtitleDecodeSession?
    var ass: ASSSubtitleSource?
    if let id {
      if let entry = external[id] {
        track = entry.track
        ass = entry.assScript.flatMap {
          ASSSubtitleSource(script: $0, fonts: fonts, hostFonts: hostFonts, meter: renderMeter)
        }
      } else {
        let tracks = await demux.tracks
        guard !isClosed, generation == state.selectionGeneration else { return }
        guard let selected = tracks.first(where: { $0.id == id }), selected.kind == .subtitle else {
          throw UmbelError.trackUnavailable("no subtitle track \(id.rawValue)")
        }
        let decoder = try await demux.makeSubtitleDecoder(for: id)
        guard !isClosed, generation == state.selectionGeneration else {
          decoder.close()
          return
        }
        let source = selected.codecName == "ass" || selected.codecName == "ssa"
          ? ASSSubtitleSource(
            header: decoder.subtitleHeader, fonts: fonts, hostFonts: hostFonts, meter: renderMeter)
          : nil
        session = SubtitleDecodeSession(
          decoder: decoder, assSource: source,
          fallbackCanvas: tracks.first { $0.kind == .video }?.video.map {
            CGSize(width: $0.width, height: $0.height)
          })
        track = selected
      }
    }
    let old = state.decoder
    state.track = track
    state.decoder = session
    state.externalASS = ass
    revision += 1
    if old != nil || session != nil {
      replayRevision += 1
      state.replayRevision = replayRevision
    }
    await old?.close()
  }

  internal var renderStatistics: UmbelSubtitleRenderStatistics { renderMeter.statistics }

  /// Sources made afterwards get the fonts as they are made; those showing
  /// now get them here, and redraw.
  internal func setHostFonts(_ fonts: UmbelSubtitleFonts) async {
    guard !isClosed, fonts != hostFonts else { return }
    hostFonts = fonts
    revision += 1
    for state in [primary, secondary] {
      await (state.externalASS ?? state.decoder?.assSource)?.use(fonts)
    }
  }

  internal func loadEmbeddedFonts() async {
    let loaded = EmbeddedFont.fonts(from: await demux.attachments())
    guard !isClosed else { return }
    fonts = loaded
  }

  internal func addExternal(
    _ source: any UmbelSource, language: String?, title: String?
  ) async throws -> UmbelTrack {
    guard !isClosed else { throw CancellationError() }
    let id = UmbelTrack.ID(rawValue: nextExternalID)
    nextExternalID += 1
    let loaded = try await ExternalSubtitleLoader.load(
      source, id: id, language: language, title: title)
    guard !isClosed else { throw CancellationError() }
    external[id] = loaded
    externalOrder.append(id)
    return loaded.track
  }

  internal func cues(
    atClock time: CMTime, for slot: UmbelSubtitleSlot = .primary
  ) async -> [UmbelSubtitleCue] {
    while true {
      let version = revision
      let result = await cues(at: CMTimeSubtract(time, state(for: slot).delay), for: slot)
      if version == revision { return result }
    }
  }

  internal func cues(
    at time: CMTime, for slot: UmbelSubtitleSlot = .primary
  ) async -> [UmbelSubtitleCue] {
    let state = state(for: slot)
    guard let track = state.track else { return [] }
    if let entry = external[track.id] { return entry.timeline.cues(at: time) }
    guard let decoder = state.decoder else { return [] }
    let result = await readEmbeddedCues(decoder, time)
    // Failed and no-op requests do not replace the committed source. Only its
    // identity determines whether this result still belongs to the visible layer.
    guard state.decoder === decoder, state.track?.id == track.id, !isClosed else { return [] }
    return result
  }

  internal func render(
    at time: CMTime, in size: CGSize, picture: CGRect, videoSize: CGSize?
  ) async -> UmbelSubtitleFrame {
    while true {
      let version = revision
      var bitmaps: [UmbelSubtitleBitmap] = []
      var changed = renderedRevision != version
      for slot in UmbelSubtitleSlot.allCases {
        let state = state(for: slot)
        let shifted = CMTimeSubtract(time, state.delay)
        let frame: UmbelSubtitleFrame
        if let ass = state.externalASS ?? state.decoder?.assSource {
          frame = await ass.render(at: shifted, in: size, videoSize: videoSize, scale: state.scale)
        } else {
          let cues = await cues(at: shifted, for: slot)
          frame = state.textRenderer.render(cues, in: size, picture: picture, scale: state.scale)
        }
        bitmaps += state.placement.apply(to: frame.bitmaps, in: size)
        changed = changed || frame.isChanged
      }
      guard version == revision else { continue }
      renderedRevision = version
      return UmbelSubtitleFrame(bitmaps: bitmaps, isChanged: changed)
    }
  }

  internal func snapshot(at time: CMTime, in size: CGSize, videoSize: CGSize?) async -> [UmbelSubtitleBitmap] {
    while true {
      let version = revision
      var bitmaps: [UmbelSubtitleBitmap] = []
      for slot in UmbelSubtitleSlot.allCases {
        let state = state(for: slot)
        let shifted = CMTimeSubtract(time, state.delay)
        let drawn: [UmbelSubtitleBitmap]
        if let ass = state.externalASS ?? state.decoder?.assSource {
          drawn = await ass.snapshot(at: shifted, in: size, videoSize: videoSize, scale: state.scale)
        } else {
          let cues = await cues(at: shifted, for: slot)
          drawn = UmbelSubtitleRenderer().render(
            cues, in: size, picture: CGRect(origin: .zero, size: size), scale: state.scale).bitmaps
        }
        bitmaps += state.placement.apply(to: drawn, in: size)
      }
      if version == revision { return bitmaps }
    }
  }

  /// Seek early enough for either selected track at its display offset,
  /// bounded to ten seconds before the media target.
  internal func prerollStart(before target: CMTime) async -> CMTime? {
    var earliest: CMTime?
    for (id, requirement) in replayRequirements(at: target) {
      guard let start = await demux.indexedTime(of: id, atOrBefore: requirement.time) else { continue }
      let reach = target.seconds - start.seconds
      if reach > 0, reach <= 10 { earliest = earliest.map { min($0, start) } ?? start }
    }
    return earliest
  }

  internal func positionDemuxer(for target: CMTime) async throws {
    if let start = await prerollStart(before: target) {
      try await demux.seek(to: start)
      return
    }
    try await demux.seek(to: target)
    if let start = await prerollStart(before: target) { try await demux.seek(to: start) }
  }

  /// Both subtitle slots may show one track at different offsets. Replay
  /// must cover the earlier requested subtitle time as well as the picture.
  internal func replayRequirements(
    at target: CMTime, changedSince revision: Int? = nil
  ) -> [UmbelTrack.ID: SubtitleReplayRequirement] {
    var requirements: [UmbelTrack.ID: SubtitleReplayRequirement] = [:]
    for slot in UmbelSubtitleSlot.allCases {
      let state = state(for: slot)
      if let revision, state.replayRevision <= revision { continue }
      guard let track = state.track, let decoder = state.decoder else { continue }
      let time = target - state.delay
      let previous = requirements[track.id]
      requirements[track.id] = SubtitleReplayRequirement(
        time: previous.map { min($0.time, time) } ?? time,
        requiresCompleteHistory: decoder.requiresCompleteHistory || previous?.requiresCompleteHistory == true)
    }
    return requirements
  }

  internal func replaySnapshot(at target: CMTime, changedSince revision: Int? = nil) -> SubtitleReplaySnapshot {
    SubtitleReplaySnapshot(revision: replayRevision,
                           requirements: replayRequirements(at: target, changedSince: revision))
  }

  internal func isCurrent(_ snapshot: SubtitleReplaySnapshot) -> Bool {
    !isClosed && snapshot.revision == replayRevision
  }

  internal func flushEmbedded() async {
    revision += 1
    for slot in UmbelSubtitleSlot.allCases { await state(for: slot).decoder?.flush() }
    revision += 1
  }

  internal func close() async {
    isClosed = true
    revision += 1
    replayRevision += 1
    let sessions = [primary.decoder, secondary.decoder]
    for state in [primary, secondary] {
      state.selectionGeneration += 1
      state.track = nil
      state.decoder = nil
      state.externalASS = nil
    }
    external.removeAll()
    externalOrder.removeAll()
    for session in sessions { await session?.close() }
  }
}

/// What a subtitle decoder needs after flushing its native and display state.
internal struct SubtitleReplayRequirement: Sendable {
  let time: CMTime
  var requiresCompleteHistory = false
}

internal struct SubtitleReplaySnapshot: Sendable {
  let revision: Int
  let requirements: [UmbelTrack.ID: SubtitleReplayRequirement]
}
