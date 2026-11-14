import CoreGraphics
import CoreMedia
import Foundation

/// An RGBA colour, each component in 0...1.
public struct UmbelColor: Sendable, Equatable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public static let white = UmbelColor(red: 1, green: 1, blue: 1)
  public static let black = UmbelColor(red: 0, green: 0, blue: 0)
}

/// Where a cue sits on screen, numbered like a keypad — the numbering ASS
/// `\an` uses, so styled subtitles map onto it without translation.
public enum UmbelSubtitleAlignment: Int, Sendable, CaseIterable {
  case bottomLeft = 1, bottomCenter, bottomRight
  case middleLeft, center, middleRight
  case topLeft, topCenter, topRight

  public enum Vertical: Sendable { case bottom, middle, top }
  public enum Horizontal: Sendable { case left, center, right }

  public var vertical: Vertical {
    switch rawValue {
    case 1...3: return .bottom
    case 4...6: return .middle
    default: return .top
    }
  }

  public var horizontal: Horizontal {
    switch rawValue % 3 {
    case 1: return .left
    case 2: return .center
    default: return .right
    }
  }
}

/// Distances from the edges of the picture, as fractions of it: left and right
/// of its width, vertical of its height.
public struct UmbelSubtitleMargins: Sendable, Equatable {
  public var left: Double
  public var right: Double
  /// From the bottom for bottom-aligned cues, from the top for top-aligned
  /// ones; unused for the middle row.
  public var vertical: Double

  public init(left: Double, right: Double, vertical: Double) {
    self.left = left
    self.right = right
    self.vertical = vertical
  }
}

/// A bitmap subtitle's picture and where it goes.
public struct UmbelSubtitleImage: @unchecked Sendable, Equatable {
  /// Premultiplied BGRA. `CGImage` is immutable, which is what makes sharing
  /// it across isolation domains safe.
  public let image: CGImage
  /// Position and size as fractions of the picture, origin top-left. The
  /// image is scaled to fill it.
  public let relativeFrame: CGRect

  public init(image: CGImage, relativeFrame: CGRect) {
    self.image = image
    self.relativeFrame = relativeFrame
  }

  /// The same image object, not merely the same pixels: comparing pixels
  /// every frame would cost what the comparison is meant to save.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.image === rhs.image && lhs.relativeFrame == rhs.relativeFrame
  }
}

/// One subtitle event: what to show, when, and how.
///
/// Structure rather than a picture, so a host can lay it out itself — for
/// accessibility settings or its own look — and still hand it to
/// `UmbelSubtitleRenderer` when a picture is all it needs.
///
/// Bitmap formats — Blu-ray PGS, DVD, DVB — arrive as a picture already:
/// `image` is set and `runs` is empty. One type for both, so a host asking
/// what shows now gets one list.
///
/// Sizes are fractions of the picture height, the way ASS scales everything by
/// its `PlayResY`; the same cue then looks the same at any window size.
public struct UmbelSubtitleCue: Sendable, Equatable {
  /// A stretch of text sharing one style.
  public struct Run: Sendable, Equatable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderlined: Bool
    public var isStruckThrough: Bool
    public var color: UmbelColor

    public init(
      text: String,
      isBold: Bool = false,
      isItalic: Bool = false,
      isUnderlined: Bool = false,
      isStruckThrough: Bool = false,
      color: UmbelColor = .white
    ) {
      self.text = text
      self.isBold = isBold
      self.isItalic = isItalic
      self.isUnderlined = isUnderlined
      self.isStruckThrough = isStruckThrough
      self.color = color
    }
  }

  public var start: CMTime
  /// Nil means "until the next cue starts".
  public var end: CMTime?
  public var runs: [Run]
  public var alignment: UmbelSubtitleAlignment
  /// Font size as a fraction of the picture height.
  public var relativeFontSize: Double
  public var margins: UmbelSubtitleMargins
  public var outlineColor: UmbelColor
  /// Outline width as a fraction of the picture height.
  public var relativeOutlineWidth: Double
  /// The font the author asked for. Renderers fall back when it is missing.
  public var fontName: String?
  /// The picture of a bitmap subtitle; nil for text.
  public var image: UmbelSubtitleImage?

  public init(
    start: CMTime,
    end: CMTime?,
    runs: [Run],
    alignment: UmbelSubtitleAlignment = .bottomCenter,
    relativeFontSize: Double = 16.0 / 288,
    margins: UmbelSubtitleMargins = .init(left: 10.0 / 384, right: 10.0 / 384, vertical: 10.0 / 288),
    outlineColor: UmbelColor = .black,
    relativeOutlineWidth: Double = 1.0 / 288,
    fontName: String? = nil,
    image: UmbelSubtitleImage? = nil
  ) {
    self.start = start
    self.end = end
    self.runs = runs
    self.alignment = alignment
    self.relativeFontSize = relativeFontSize
    self.margins = margins
    self.outlineColor = outlineColor
    self.relativeOutlineWidth = relativeOutlineWidth
    self.fontName = fontName
    self.image = image
  }

  /// The text; empty for a bitmap subtitle.
  public var plainText: String { runs.map(\.text).joined() }
}
