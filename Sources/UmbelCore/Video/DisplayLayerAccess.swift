import AVFoundation
import Foundation

/// Synchronous entry to the display layer's actor for APIs whose callers
/// must observe completion before submitting more pictures or flushing.
internal struct DisplayLayerAccess: @unchecked Sendable {
  // Older SDKs do not describe the layer's actor. Carry only its reference
  // across threads; dereference it exclusively inside the main-actor call.
  private let layer: AVSampleBufferDisplayLayer

  // dispatchMain may service the main queue on a non-main pthread. The
  // immutable key is installed once; Dispatch owns all access to its value.
  private final class MainQueueIdentity: @unchecked Sendable {
    let key = DispatchSpecificKey<Bool>()
    init() { DispatchQueue.main.setSpecific(key: key, value: true) }
    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
  }
  private static let mainQueue = MainQueueIdentity()

  init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

  func sync<Result: Sendable>(
    _ operation: @MainActor @Sendable (AVSampleBufferDisplayLayer) throws -> Result
  ) rethrows -> Result {
    try Self.sync { try operation(layer) }
  }

  /// Enter before taking any lock also used on the main thread. A caller
  /// on another thread must leave the main thread free to service the call.
  static func sync<Result: Sendable>(
    _ operation: @MainActor @Sendable () throws -> Result
  ) rethrows -> Result {
    if Thread.isMainThread || mainQueue.isCurrent {
      return try MainActor.assumeIsolated { try operation() }
    }
    return try DispatchQueue.main.sync {
      try MainActor.assumeIsolated { try operation() }
    }
  }
}
