import Foundation
import UmbelCore

/// Events as they happen, for measuring against another player: with
/// `UMBEL_TRACE=1`, one line each, printed at once so a script reading them
/// can time them on arrival.
///
///     [trace] 412 first-frame 0.000
///     [trace] 5012 phase buffering
///     [trace] 9000 seek 600.0
///     [trace] 9210 seek-frame 600.042
///
/// The number is milliseconds since the player started, for reading the
/// log by eye.
enum Trace {
  static let isOn = ProcessInfo.processInfo.environment["UMBEL_TRACE"] == "1"
  private static let origin = ProcessInfo.processInfo.systemUptime

  /// Call first thing, so times count from the start.
  static func begin() { _ = origin }

  static func log(_ event: String) {
    guard isOn else { return }
    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - origin) * 1000)
    print("[trace] \(milliseconds) \(event)")
    fflush(stdout)
  }

  static func startPlaybackDiagnostics(_ diagnostics: UmbelPlaybackDiagnostics?) -> Task<Void, Never>? {
    guard let diagnostics else { return nil }
    return Task.detached(priority: .utility) {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = .sortedKeys
      var sequence: UInt64 = 0
      func export() {
        let snapshot = diagnostics.snapshot(after: sequence)
        if let first = snapshot.events.first, first.sequence > sequence + 1 {
          print("[playback-diagnostic] lost \(first.sequence - sequence - 1) events")
        }
        for event in snapshot.events {
          do {
            let data = try encoder.encode(event)
            print("[playback-diagnostic] \(String(decoding: data, as: UTF8.self))")
          } catch { print("[playback-diagnostic] export failed: \(error)") }
        }
        sequence = snapshot.latestSequence
        fflush(stdout)
      }
      while !Task.isCancelled {
        export()
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
      export()
    }
  }
}
