import CoreGraphics

/// The pixel budget for a composited surface, separate from its color precision.
internal struct CompositeRenderSize {
  private var limit: CGSize?
  private var lastGeometry: [Int]?

  mutating func setLimit(_ size: CGSize?) -> Bool {
    let valid = size.flatMap { size in
      size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 ? size : nil
    }
    guard valid != limit else { return false }
    limit = valid
    return true
  }

  func fitting(_ source: CGSize) -> CGSize {
    guard let limit, source.width > limit.width || source.height > limit.height else { return source }
    return PictureFit.rect(fitting: source, in: limit).size
  }

  mutating func resetDiagnostics() { lastGeometry = nil }

  mutating func record(
    sourceWidth: Int, sourceHeight: Int, width: Int, height: Int,
    diagnostics: UmbelPlaybackDiagnostics?, output: String
  ) {
    let geometry = [sourceWidth, sourceHeight, width, height]
    guard geometry != lastGeometry else { return }
    diagnostics?.record("video_render_size", values: [
      "sourceWidth": Double(sourceWidth), "sourceHeight": Double(sourceHeight),
      "width": Double(width), "height": Double(height)],
      labels: ["output": output, "reason": limit == nil ? "sourceSize" : "outputSizeLimit"])
    lastGeometry = geometry
  }
}
