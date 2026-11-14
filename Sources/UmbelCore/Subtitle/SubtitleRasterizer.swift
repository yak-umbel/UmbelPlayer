import CoreGraphics
import CoreText
import Foundation

/// Draws one cue into an image with CoreText.
internal enum SubtitleRasterizer {
  struct Raster {
    let image: CGImage
    /// Transparent border kept around the text for the outline.
    let padding: CGFloat
  }

  /// Marks runs to strike through. CoreText lays strikethrough out but does
  /// not draw it, so it is drawn here by hand.
  private static let strikeKey = NSAttributedString.Key("UmbelStrikethrough")

  /// `scale` times the size the cue asks for; its outline grows with it.
  static func rasterize(_ cue: UmbelSubtitleCue, in size: CGSize, scale: Double = 1) -> Raster? {
    guard !cue.plainText.isEmpty else { return nil }
    let base = baseFont(named: cue.fontName, height: cue.relativeFontSize * size.height * scale)
    let outline = max(0, cue.relativeOutlineWidth * size.height * scale)
    let padding = ceil(outline) + 1
    let available = size.width * (1 - cue.margins.left - cue.margins.right) - 2 * padding
    guard available >= 1 else { return nil }

    let fill = attributed(cue, base: base, outline: nil)
    let fillSetter = CTFramesetterCreateWithAttributedString(fill)
    let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
      fillSetter, CFRange(), nil, CGSize(width: available, height: .greatestFiniteMagnitude), nil)
    let textSize = CGSize(width: ceil(fitted.width), height: ceil(fitted.height))
    guard textSize.width > 0, textSize.height > 0 else { return nil }

    let width = Int(textSize.width + 2 * padding)
    let height = Int(textSize.height + 2 * padding)
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

    let path = CGPath(
      rect: CGRect(origin: CGPoint(x: padding, y: padding), size: textSize), transform: nil)
    // Outline first, fill over it: the stroke is centred on the glyph edge,
    // and the fill covers its inner half, leaving a border of `outline`.
    if outline > 0 {
      context.setLineJoin(.round)
      let stroke = attributed(cue, base: base, outline: outline)
      CTFrameDraw(
        CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(stroke), CFRange(), path, nil),
        context)
    }
    let frame = CTFramesetterCreateFrame(fillSetter, CFRange(), path, nil)
    CTFrameDraw(frame, context)
    drawStrikethrough(in: frame, context: context)

    return context.makeImage().map { Raster(image: $0, padding: padding) }
  }

  /// ASS sizes a font by its full height, ascender to descender, the way
  /// VSFilter and libass do — not by its em square. Authored sizes only look
  /// right when read the same way.
  private static func baseFont(named name: String?, height: CGFloat) -> CTFont {
    let probe = probeFont(named: name)
    let fullHeight = CTFontGetAscent(probe) + CTFontGetDescent(probe)
    let emSize = max(1, height) * probeSize / max(fullHeight, 1)
    return CTFontCreateCopyWithAttributes(probe, emSize, nil, nil)
  }

  private static let probeSize: CGFloat = 100

  /// The font `name` asks for at the probe size, or the system font. Finding
  /// a font by family name is slow and cues ask for the same few names again
  /// and again, so each is looked up once.
  static func probeFont(named name: String?) -> CTFont {
    probes.font(for: name ?? "") { lookUpProbeFont(named: name) }
  }

  private static let probes = ProbeFonts()

  /// Looked-up fonts by name, dropped all at once past a bound: an authored
  /// script names only a handful, so the bound is only a guard.
  private final class ProbeFonts: @unchecked Sendable {
    private let lock = NSLock()
    private var fonts: [String: CTFont] = [:]

    func font(for name: String, lookUp: () -> CTFont) -> CTFont {
      lock.lock()
      defer { lock.unlock() }
      if let font = fonts[name] { return font }
      if fonts.count >= 64 { fonts.removeAll() }
      let font = lookUp()
      fonts[name] = font
      return font
    }
  }

  private static func lookUpProbeFont(named name: String?) -> CTFont {
    var probe = CTFontCreateUIFontForLanguage(.system, probeSize, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, probeSize, nil)
    if let name {
      let requested = CTFontCreateWithName(name as CFString, probeSize, nil)
      // CTFontCreateWithName never fails; it substitutes. Keep the result
      // only if it is the family that was asked for.
      let family = CTFontCopyFamilyName(requested) as String
      if family.caseInsensitiveCompare(name) == .orderedSame { probe = requested }
    }
    return probe
  }

  private static func attributed(
    _ cue: UmbelSubtitleCue, base: CTFont, outline: CGFloat?
  ) -> CFAttributedString {
    let text = NSMutableAttributedString()
    for run in cue.runs {
      let font = styled(base, bold: run.isBold, italic: run.isItalic)
      var attributes: [NSAttributedString.Key: Any] = [
        kCTFontAttributeName as NSAttributedString.Key: font,
      ]
      if let outline {
        let color = cgColor(cue.outlineColor)
        attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] = color
        attributes[kCTStrokeColorAttributeName as NSAttributedString.Key] = color
        // Percent of the point size; positive means stroke only.
        attributes[kCTStrokeWidthAttributeName as NSAttributedString.Key] =
          2 * outline / CTFontGetSize(font) * 100
      } else {
        attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] = cgColor(run.color)
        if run.isUnderlined {
          attributes[kCTUnderlineStyleAttributeName as NSAttributedString.Key] =
            CTUnderlineStyle.single.rawValue
        }
        if run.isStruckThrough { attributes[strikeKey] = cgColor(run.color) }
      }
      text.append(NSAttributedString(string: run.text, attributes: attributes))
    }

    var alignment: CTTextAlignment
    switch cue.alignment.horizontal {
    case .left: alignment = .left
    case .center: alignment = .center
    case .right: alignment = .right
    }
    let paragraph = withUnsafeBytes(of: &alignment) { bytes in
      var setting = CTParagraphStyleSetting(
        spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
      return CTParagraphStyleCreate(&setting, 1)
    }
    text.addAttribute(
      kCTParagraphStyleAttributeName as NSAttributedString.Key, value: paragraph,
      range: NSRange(location: 0, length: text.length))
    return text
  }

  /// The family's bold or italic face when it has one. Italic is slanted by
  /// hand when it does not — CJK fonts rarely ship an italic, and dropping
  /// the style silently would lose what the author marked.
  private static func styled(_ font: CTFont, bold: Bool, italic: Bool) -> CTFont {
    var traits: CTFontSymbolicTraits = []
    if bold { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    guard !traits.isEmpty else { return font }
    if let exact = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) {
      return exact
    }
    let boldOnly = bold
      ? CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
      : font
    guard italic else { return boldOnly }
    var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
    return CTFontCreateCopyWithAttributes(boldOnly, CTFontGetSize(boldOnly), &slant, nil)
  }

  private static func drawStrikethrough(in frame: CTFrame, context: CGContext) {
    let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    let frameOrigin = CTFrameGetPath(frame).boundingBox.origin

    for (line, origin) in zip(lines, origins) {
      for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let color = attributes[strikeKey] else { continue }
        let font = attributes[kCTFontAttributeName] as! CTFont   // every run carries one
        var start = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &start)
        let width = CTRunGetTypographicBounds(run, CFRange(), nil, nil, nil)
        let thickness = max(1, CTFontGetSize(font) / 18)
        let y = frameOrigin.y + origin.y + CTFontGetXHeight(font) / 2
        context.setFillColor(color as! CGColor)   // stored as a CGColor above
        context.fill(CGRect(
          x: frameOrigin.x + origin.x + start.x, y: y - thickness / 2,
          width: CGFloat(width), height: thickness))
      }
    }
  }

  private static func cgColor(_ color: UmbelColor) -> CGColor {
    CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
  }
}
