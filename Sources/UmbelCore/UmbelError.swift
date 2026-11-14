import Foundation

/// What playback can fail with.
///
/// Every case carries enough for a host to decide whether a retry is worth it
/// and whether to tell the user. No failure comes without a reason.
public enum UmbelError: Error, Sendable, Equatable {
  /// The source is unavailable: the network gone, a file missing, no
  /// permission.
  case sourceUnavailable(detail: String)
  /// The address has a scheme the source cannot read, named here in lower
  /// case. A source of a host's own throws this for such an address.
  case unsupportedScheme(String)
  /// The container cannot be read.
  case unsupportedContainer(String)
  /// The codec is not supported, and there is no fallback.
  case unsupportedCodec(String)
  /// A decoder failed to be made or to run.
  case decoderFailure(codec: String, code: Int32)
  /// Rendering is unavailable: no Metal device, the display layer gone.
  case renderUnavailable(reason: String)
  /// Interrupted from outside: an engine switch, reclaimed in the background.
  case interrupted
  /// The source or container cannot seek.
  case seekUnsupported
  /// No audio output: no device, taken by the system, a format not supported.
  case audioOutputUnavailable(reason: String)
  /// No video rendering: no Metal device, a shader that fails to compile, a
  /// texture cache that cannot be made.
  case videoRenderUnavailable(reason: String)
  /// No picture is currently available to capture.
  case snapshotUnavailable(reason: String)
  /// A colour matrix this version does not support. Said plainly rather than
  /// drawn as BT.709 without a word.
  case unsupportedColorMatrix(String)

  /// The track does not exist, or is not the kind the operation needs.
  case trackUnavailable(String)
  /// The disk cache could not be set up: its folder cannot be created, or
  /// another cache in this process already uses it. Only construction throws
  /// this; once running, a disk that misbehaves means reading past the cache.
  case cacheUnavailable(reason: String)
  /// Frame-by-frame HDR only the system can show — DV without a base layer
  /// of its own, "DV P5" — and the system here cannot.
  case unsupportedDynamicHDR(String)
  /// The picture has to go to the system's display layer (DV P5), and the
  /// renderer given has none: the host gives a `SwitchingVideoRenderer`
  /// with a `SampleBufferVideoRenderer` for picture in picture.
  case displayLayerRequired
}

public extension UmbelError {
  /// Whether retrying as it was is worth it.
  var isRetryable: Bool {
    switch self {
    case .sourceUnavailable, .renderUnavailable, .interrupted,
         .audioOutputUnavailable, .videoRenderUnavailable:
      return true
    case .unsupportedScheme, .unsupportedContainer, .unsupportedCodec, .decoderFailure,
         .seekUnsupported, .unsupportedColorMatrix, .trackUnavailable, .cacheUnavailable,
         .unsupportedDynamicHDR, .displayLayerRequired, .snapshotUnavailable:
      // Another track number is the caller's business; retrying the same one
      // gets no better.
      return false
    }
  }
}

/// Readable descriptions, so a host that only logs `localizedDescription`
/// still records what went wrong.
///
/// Written in the same language as the details the cases already carry; a host
/// that shows errors to users should switch on the case and word it itself.
extension UmbelError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable(let detail):
      return "source unavailable: \(detail)"
    case .unsupportedScheme(let scheme):
      return "address scheme not supported: \(scheme)"
    case .unsupportedContainer(let format):
      return "container cannot be read: \(format)"
    case .unsupportedCodec(let codec):
      return "codec not supported: \(codec)"
    case .decoderFailure(let codec, let code):
      return "decoding failed: \(codec) (code \(code))"
    case .renderUnavailable(let reason):
      return "rendering unavailable: \(reason)"
    case .interrupted:
      return "playback interrupted"
    case .seekUnsupported:
      return "this content cannot seek"
    case .audioOutputUnavailable(let reason):
      return "audio output unavailable: \(reason)"
    case .videoRenderUnavailable(let reason):
      return "video rendering unavailable: \(reason)"
    case .snapshotUnavailable(let reason):
      return "no snapshot: \(reason)"
    case .unsupportedColorMatrix(let matrix):
      return "colour matrix not supported: \(matrix)"
    case .trackUnavailable(let detail):
      return "track unavailable: \(detail)"
    case .cacheUnavailable(let reason):
      return "disk cache unavailable: \(reason)"
    case .unsupportedDynamicHDR(let what):
      return "dynamic HDR not supported here: \(what)"
    case .displayLayerRequired:
      return "this picture needs a sample buffer display layer, and the renderer has none"
    }
  }
}

internal extension UmbelError {
  /// Every failure the session reports carries an `UmbelError`; anything else
  /// that surfaces from below is folded into the closest case rather than lost.
  static func wrapping(_ error: Error) -> UmbelError {
    if let umbel = error as? UmbelError { return umbel }
    if error is CancellationError { return .interrupted }
    if let system = error as? URLError, let refusal = schemeRefusal(system) { return refusal }
    return .sourceUnavailable(detail: detail(for: error))
  }

  /// What the URL system's "unsupported URL" says when it is about a scheme:
  /// nil for any other error, for an address with no scheme at all, and for
  /// a web one, whose scheme cannot be what is wrong with it. Taken from the
  /// address that failed, which after a redirect is not the one asked for.
  static func schemeRefusal(_ error: URLError) -> UmbelError? {
    guard error.code == .unsupportedURL,
          let scheme = error.failingURL?.scheme?.lowercased(),
          scheme != "http", scheme != "https" else { return nil }
    return .unsupportedScheme(scheme)
  }

  /// Words for an error from below, in a detail. The system's own words
  /// follow the device's language, so a system error is named by its domain
  /// and code; an `UmbelError` by its description; an error of Swift's own
  /// by its case.
  static func detail(for error: Error) -> String {
    if let umbel = error as? UmbelError { return umbel.errorDescription ?? "\(umbel)" }
    guard type(of: error) is NSError.Type else { return String(describing: error) }
    let system = error as NSError
    return "\(system.domain) error \(system.code)"
  }
}
