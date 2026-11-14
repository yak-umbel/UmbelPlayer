import CoreGraphics
import Foundation

/// A track in the container.
///
/// Fields come from what the container declares, not from decoding. What is
/// not declared is nil — not 0 or an empty string standing for "none": a
/// caller has to tell "declared 0" from "not declared".
public struct UmbelTrack: Sendable, Equatable, Identifiable {
  /// The stream's index in the container. Stable within a session, not
  /// across sessions.
  public struct ID: Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
  }

  public enum Kind: String, Sendable, CaseIterable {
    case video
    case audio
    case subtitle
  }

  public struct VideoDescription: Sendable, Equatable {
    /// In stored pixels, which need not be square.
    public let width: Int
    public let height: Int
    /// The nominal frame rate the container declares; nil if none.
    public let nominalFrameRate: Double?
    /// The width of one pixel over its height as shown: 1 for square pixels,
    /// 16/11 for a 352×288 picture shown 16:9. 1 when nothing says otherwise.
    public let pixelAspectRatio: Double
    /// SDR, PQ or HLG, as declared before any frame is decoded. A DV base
    /// layer that declares none takes what its configuration names.
    public let transfer: UmbelTransferFunction
    /// Frame-by-frame HDR on top: DV, by profile. Nil for other tracks.
    public let dynamicHDR: UmbelDynamicHDR?
    /// How far the container says the picture is turned, clockwise, to be
    /// shown upright; `.none` when it says nothing, flips the picture, or
    /// asks for an angle that is no right angle.
    public let rotation: UmbelVideoRotation
    public let signal: VideoSignalDescription?

    public init(
      width: Int, height: Int, nominalFrameRate: Double?, pixelAspectRatio: Double = 1,
      transfer: UmbelTransferFunction = .sdr, dynamicHDR: UmbelDynamicHDR? = nil,
      rotation: UmbelVideoRotation = .none, signal: VideoSignalDescription?
    ) {
      self.width = width
      self.height = height
      self.nominalFrameRate = nominalFrameRate
      self.pixelAspectRatio = pixelAspectRatio
      self.transfer = transfer
      self.dynamicHDR = dynamicHDR
      self.rotation = rotation
      self.signal = signal
    }

    /// The rotation the pictures are drawn with: the declared one, except on
    /// the system's display path (DV profile 5), which shows them as stored.
    internal var appliedRotation: UmbelVideoRotation {
      dynamicHDR?.requiresSystemDisplay == true ? .none : rotation
    }

    /// The picture as it is drawn: stored pixels widened to their shape, then
    /// turned by the rotation applied.
    private var shownSize: CGSize {
      appliedRotation.turned(CGSize(width: Double(width) * pixelAspectRatio, height: Double(height)))
    }

    /// The width the picture is drawn at, turned as it is drawn.
    public var displayWidth: Int { Int(shownSize.width.rounded()) }
    /// The height the picture is drawn at, turned as it is drawn.
    public var displayHeight: Int { Int(shownSize.height.rounded()) }
  }

  public struct AudioDescription: Sendable, Equatable {
    public let channelCount: Int
    public let sampleRate: Int

    public init(channelCount: Int, sampleRate: Int) {
      self.channelCount = channelCount
      self.sampleRate = sampleRate
    }
  }

  public let id: ID
  public let kind: Kind
  /// A neutral technical name: "h264", "hevc", "eac3". Never a protected
  /// trademark.
  public let codecName: String
  /// ISO 639-2 language code; nil if none.
  public let language: String?
  public let title: String?
  public let isDefault: Bool
  /// Forced subtitles. Always false for other tracks.
  public let isForced: Bool
  /// Set when kind == .video.
  public let video: VideoDescription?
  /// Set when kind == .audio.
  public let audio: AudioDescription?
  /// Added from a file outside the container, such as a sidecar subtitle.
  public let isExternal: Bool
  /// Whether this engine can decode the track. Unlike the fields above, this
  /// is about the engine, not the container: a track can be declared in full
  /// and still be one no decoder here reads, such as AC-4. Such a track is
  /// never chosen automatically, and choosing it throws `unsupportedCodec`.
  public let isDecodable: Bool

  public init(
    id: ID,
    kind: Kind,
    codecName: String,
    language: String?,
    title: String?,
    isDefault: Bool,
    isForced: Bool,
    video: VideoDescription?,
    audio: AudioDescription?,
    isExternal: Bool = false,
    isDecodable: Bool = true
  ) {
    self.id = id
    self.kind = kind
    self.codecName = codecName
    self.language = language
    self.title = title
    self.isDefault = isDefault
    self.isForced = isForced
    self.video = video
    self.audio = audio
    self.isExternal = isExternal
    self.isDecodable = isDecodable
  }
}
