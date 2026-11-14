import CoreMedia
import Foundation

/// A timestamp observation, not confirmation that a picture reached the display.
/// Numeric times are seconds unless the field names samples, ticks or a time base.
/// Missing and nonfinite timestamps are omitted from `values`.
public struct UmbelPlaybackDiagnosticEvent: Sendable, Codable, Equatable {
  public let traceID: UUID
  public let sequence: UInt64
  public let date: Date
  /// The system host clock, shared with render anchors.
  public let hostTime: Double
  public let name: String
  public let values: [String: Double]
  public let labels: [String: String]
}

/// Opt-in, bounded observations across a session's timestamp pipeline.
/// Pass one instance to `PlaybackSession`, then read incremental snapshots
/// away from the display loop. No callbacks, file writes or network access
/// occur on the playback executors. Event names and fields are diagnostic
/// data and may grow; readers should tolerate unknown or missing fields.
public final class UmbelPlaybackDiagnostics: @unchecked Sendable {
  public struct Snapshot: Sendable {
    public let events: [UmbelPlaybackDiagnosticEvent]
    public let latestSequence: UInt64
    /// Total events replaced since recording began, not just since this read.
    public let overwrittenEventCount: UInt64
  }

  public let id = UUID()
  public let capacity: Int
  private let lock = NSLock()
  private var history: [UmbelPlaybackDiagnosticEvent?]
  private var sequence: UInt64 = 0

  public init(capacity: Int = 20_000) {
    self.capacity = max(1, capacity)
    self.history = Array(repeating: nil, count: self.capacity)
  }

  /// Ordered events newer than `sequence`. A gap before the first returned
  /// event means the reader fell behind the bounded history.
  public func snapshot(after sequence: UInt64 = 0) -> Snapshot {
    lock.withLock {
      let overwritten = self.sequence > UInt64(capacity) ? self.sequence - UInt64(capacity) : 0
      var events: [UmbelPlaybackDiagnosticEvent] = []
      if sequence < self.sequence {
        let first = max(sequence + 1, overwritten + 1)
        events.reserveCapacity(Int(self.sequence - first + 1))
        for number in first...self.sequence {
          if let event = history[Int((number - 1) % UInt64(capacity))] { events.append(event) }
        }
      }
      return Snapshot(events: events, latestSequence: self.sequence, overwrittenEventCount: overwritten)
    }
  }

  internal func record(
    _ name: String, values: [String: Double] = [:], labels: [String: String] = [:]
  ) {
    lock.withLock {
      sequence += 1
      history[Int((sequence - 1) % UInt64(capacity))] = UmbelPlaybackDiagnosticEvent(
        traceID: id, sequence: sequence, date: Date(),
        hostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
        name: name, values: values.filter { $0.value.isFinite }, labels: labels)
    }
  }
}

/// Built-in sinks receive the session's recorder without adding requirements
/// to the public output protocols or to custom implementations.
internal protocol PlaybackDiagnosticsReceiving: Sendable {
  func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) async
}

internal protocol VideoDiagnosticsReceiving: Sendable {
  func setPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?, output: String) async
}

extension UmbelPlaybackDiagnostics {
  /// What decoding `packet` of route `generation` gave, frame by frame.
  internal func recordDecoded(_ frames: [AudioFrame], from packet: DemuxPacket, generation: Int) {
    for frame in frames {
      record("audio_decoded", values: [
        "track": Double(packet.trackID.rawValue), "packetPTS": packet.presentationTime.seconds,
        "framePTS": frame.presentationTime.seconds, "samples": Double(frame.frameCount),
        "sampleRate": frame.sampleRate, "generation": Double(generation)])
    }
  }

  internal func recordDecoded(_ frames: [VideoFrame], from packet: DemuxPacket, generation: Int) {
    for frame in frames {
      record("video_decoded", values: [
        "track": Double(packet.trackID.rawValue), "packetPTS": packet.presentationTime.seconds,
        "framePTS": frame.presentationTime.seconds, "generation": Double(generation)],
        labels: ["shown": String(frame.isShown)])
    }
  }
}
