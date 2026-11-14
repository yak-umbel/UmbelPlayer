import CoreMedia
import Foundation
import UmbelFFmpegSupport

/// Limits audio retained independently of playback buffering.
public struct CachedAudioConfiguration: Sendable {
  /// Maximum retained media-time span in seconds, applied per audio track.
  public let maxDuration: Double
  /// Maximum compressed packet payload bytes, shared across audio tracks.
  public let maxBytes: Int
  /// Maximum planar Float32 sample bytes returned by one extraction.
  public let maxDecodedBytes: Int

  public init(
    maxDuration: Double = 30,
    maxBytes: Int = 8 * 1_024 * 1_024,
    maxDecodedBytes: Int = 64 * 1_024 * 1_024
  ) {
    self.maxDuration = maxDuration.isFinite ? max(0, maxDuration) : 0
    self.maxBytes = max(0, maxBytes)
    self.maxDecodedBytes = max(0, maxDecodedBytes)
  }
}

public enum CachedAudioError: Error, Sendable {
  case invalidRange
  case trackUnavailable
  case missingCoverage(available: [CMTimeRange])
  case decoderUnavailable
  case noDecodableSamples
  case outputLimitExceeded(maxBytes: Int)
}

/// PCM from the retained compressed packets. Each frame is planar Float32.
/// Covered ranges describe the samples actually returned and may be shorter
/// than the requested interval at sample or decoder boundaries. Timestamps
/// are rounded to microseconds; gaps up to one microsecond are merged.
public struct CachedAudioExtraction: Sendable {
  public let frames: [AudioFrame]
  public let coveredRanges: [CMTimeRange]

  internal init(frames: [AudioFrame]) {
    self.frames = frames
    self.coveredRanges = CachedAudioStore.mergedRanges(frames.compactMap { frame in
      guard frame.presentationTime.isNumeric, frame.duration.isNumeric,
            frame.duration > .zero else { return nil }
      return CMTimeRange(start: frame.presentationTime, duration: frame.duration)
    }, tolerance: CMTime(value: 1, timescale: 1_000_000))
  }
}

/// Value snapshot: taking it never removes packets from the live cache.
internal struct AudioPacketSnapshot: Sendable {
  let packets: [DemuxPacket]
  let parameters: FFmpegCodecParameters
  let requestedRange: CMTimeRange
  let maxDecodedBytes: Int
}

/// Actor-owned storage. Only packets with a known, positive media span count
/// as coverage; estimating absent durations could bridge a real gap.
internal struct CachedAudioStore {
  private struct Entry {
    let id: UInt64
    let packet: DemuxPacket
    let range: CMTimeRange
    let bytes: Int
  }

  private let configuration: CachedAudioConfiguration
  private let audioTracks: Set<UmbelTrack.ID>
  private let initialParameters: [UmbelTrack.ID: FFmpegCodecParameters]
  private var currentParameters: [UmbelTrack.ID: FFmpegCodecParameters]
  private var entries: [UmbelTrack.ID: [Entry]] = [:]
  private var insertionOrder: [(track: UmbelTrack.ID, id: UInt64)] = []
  private var totalBytes = 0
  private var nextID: UInt64 = 0

  init(
    configuration: CachedAudioConfiguration,
    audioTracks: Set<UmbelTrack.ID>,
    initialParameters: [UmbelTrack.ID: FFmpegCodecParameters] = [:]
  ) {
    self.configuration = configuration
    self.audioTracks = audioTracks
    self.initialParameters = initialParameters
    self.currentParameters = initialParameters
  }

  mutating func append(_ packet: DemuxPacket) {
    guard audioTracks.contains(packet.trackID) else { return }
    if let parameters = packet.decoderParameters {
      currentParameters[packet.trackID] = parameters
    }
    guard configuration.maxDuration > 0,
          configuration.maxBytes > 0, !packet.data.isEmpty,
          packet.presentationTime.isNumeric, packet.duration.isNumeric,
          packet.duration > .zero else { return }
    var retained = packet
    if retained.decoderParameters == nil {
      retained.decoderParameters = currentParameters[packet.trackID]
    }
    let range = CMTimeRange(start: packet.presentationTime, duration: packet.duration)
    guard range.end.isNumeric else { return }
    let charge = max(1, packet.data.count)
    guard charge <= configuration.maxBytes else { return }
    nextID &+= 1
    entries[packet.trackID, default: []].append(
      Entry(id: nextID, packet: retained, range: range, bytes: charge))
    insertionOrder.append((packet.trackID, nextID))
    totalBytes += charge
    trimDuration(of: packet.trackID)
    while totalBytes > configuration.maxBytes { evictOldest() }
  }

  func ranges(for track: UmbelTrack.ID) -> [CMTimeRange] {
    Self.mergedRanges((entries[track] ?? []).map(\.range))
  }

  func snapshot(for track: UmbelTrack.ID, range: CMTimeRange) throws -> AudioPacketSnapshot {
    guard range.start.isNumeric, range.duration.isNumeric, range.end.isNumeric,
          range.duration > .zero else {
      throw CachedAudioError.invalidRange
    }
    guard audioTracks.contains(track) else { throw CachedAudioError.trackUnavailable }
    let coverage = ranges(for: track)
    guard let covering = coverage.first(where: {
      $0.start <= range.start && $0.end >= range.end
    }) else {
      throw CachedAudioError.missingCoverage(available: coverage)
    }
    let retained = entries[track] ?? []
    guard let first = retained.firstIndex(where: {
      $0.range.end > covering.start && $0.range.start < covering.end
    }), let last = retained.lastIndex(where: {
      $0.range.end > range.start && $0.range.start < range.end
    }) else {
      throw CachedAudioError.missingCoverage(available: coverage)
    }
    // Decode from the start of this retained contiguous run to preserve
    // codec history. Packets can arrive out of presentation-time order, so
    // keep the arrival-order span through the last packet the request needs.
    let packets = retained[first...last].map(\.packet)
    guard let parameters = packets.first?.decoderParameters ?? initialParameters[track] else {
      throw CachedAudioError.decoderUnavailable
    }
    return AudioPacketSnapshot(
      packets: packets, parameters: parameters, requestedRange: range,
      maxDecodedBytes: configuration.maxDecodedBytes)
  }

  mutating func removeAll() {
    entries.removeAll()
    insertionOrder.removeAll()
    totalBytes = 0
    currentParameters = initialParameters
  }

  private mutating func trimDuration(of track: UmbelTrack.ID) {
    guard let newest = entries[track]?.map(\.range.end).max() else { return }
    let cutoff = newest - CMTime(seconds: configuration.maxDuration, preferredTimescale: 1_000_000)
    while let index = entries[track]?.firstIndex(where: { $0.range.start < cutoff }) {
      remove(at: index, of: track)
    }
  }

  private mutating func evictOldest() {
    while !insertionOrder.isEmpty {
      let oldest = insertionOrder.removeFirst()
      guard let index = entries[oldest.track]?.firstIndex(where: { $0.id == oldest.id }) else { continue }
      remove(at: index, of: oldest.track)
      return
    }
  }

  private mutating func remove(at index: Int, of track: UmbelTrack.ID) {
    guard let entry = entries[track]?.remove(at: index) else { return }
    if let orderIndex = insertionOrder.firstIndex(where: {
      $0.track == track && $0.id == entry.id
    }) {
      insertionOrder.remove(at: orderIndex)
    }
    totalBytes -= entry.bytes
  }

  static func mergedRanges(
    _ ranges: [CMTimeRange], tolerance: CMTime = .zero
  ) -> [CMTimeRange] {
    let sorted = ranges.sorted { $0.start < $1.start }
    var merged: [CMTimeRange] = []
    for range in sorted {
      if let last = merged.last, range.start <= last.end + tolerance {
        merged[merged.count - 1] = CMTimeRange(
          start: last.start, end: max(last.end, range.end))
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}

internal extension AudioFrame {
  /// Only complete samples within the requested interval are returned.
  func trimmed(to range: CMTimeRange) -> AudioFrame? {
    guard presentationTime.isNumeric, range.start.isNumeric, range.end.isNumeric,
          sampleRate.isFinite, sampleRate > 0,
          frameCount > 0, channelCount > 0,
          frameCount <= Int.max / channelCount,
          samples.count == frameCount * channelCount else { return nil }
    let begin = (range.start - presentationTime).seconds * sampleRate
    let end = (range.end - presentationTime).seconds * sampleRate
    guard begin.isFinite, end.isFinite else { return nil }
    let lower = Int(min(Double(frameCount), max(0, ceil(begin - 1e-8))))
    let upper = Int(min(Double(frameCount), max(0, floor(end + 1e-8))))
    guard upper > lower else { return nil }
    var result: [Float] = []
    result.reserveCapacity((upper - lower) * channelCount)
    for channel in 0..<channelCount {
      let offset = channel * frameCount
      result.append(contentsOf: samples[(offset + lower)..<(offset + upper)])
    }
    return AudioFrame(
      presentationTime: presentationTime + CMTime(seconds: Double(lower) / sampleRate, preferredTimescale: 1_000_000),
      sampleRate: sampleRate, channelCount: channelCount,
      frameCount: upper - lower, samples: result)
  }
}
