import CoreMedia
import Foundation

/// Serializes route catch-up and delivery, including across receiver awaits.
/// Every track is taken once, then fanned out to each independently owned decoder.
internal actor SubtitleFeed {
  private let cache: PacketCache
  private var routes: [SubtitleRoute] = []
  private var tail: Task<Void, Never>?

  internal init(cache: PacketCache) { self.cache = cache }

  internal func route(_ destinations: [SubtitleRoute]) async {
    let preceding = tail
    let task = Task {
      await preceding?.value
      await self.install(destinations)
    }
    tail = task
    await task.value
  }

  /// Legacy single-receiver entry point retained for internal callers.
  internal func route(
    _ track: UmbelTrack.ID?, to receiver: (any SubtitlePacketReceiver)?,
    previous: (any SubtitlePacketReceiver)?
  ) async {
    let destinations = track.flatMap { id in receiver.map { [SubtitleRoute(id: id, receiver: $0)] } }
    await route(destinations ?? [])
  }

  private func install(_ destinations: [SubtitleRoute]) async {
    let previous = routes
    routes = destinations
    let history = await cache.routeSubtitles(to: Set(destinations.map(\.id)))
    for destination in destinations {
      guard !previous.contains(where: {
        $0.id == destination.id && $0.receiver === destination.receiver
      }) else { continue }
      for packet in history[destination.id] ?? [] { await destination.receiver.receive(packet) }
    }
  }

  internal func deliver(upTo time: CMTime) async {
    let preceding = tail
    let task = Task {
      await preceding?.value
      await self.deliverCurrent(upTo: time)
    }
    tail = task
    await task.value
  }

  internal func deliver(
    _ track: UmbelTrack.ID, to receiver: any SubtitlePacketReceiver, upTo time: CMTime
  ) async {
    await deliver(upTo: time)
  }

  private func deliverCurrent(upTo time: CMTime) async {
    for id in Set(routes.map(\.id)) {
      let receivers = routes.filter { $0.id == id }.map(\.receiver)
      for packet in await cache.take(from: id, upTo: time) {
        for receiver in receivers { await receiver.receive(packet) }
      }
    }
  }
}
