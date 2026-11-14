import CoreGraphics

/// Where the picture goes in an output of another shape: as large as fits,
/// centred, the rest left black — letterboxing or pillarboxing.
internal enum PictureFit {
  /// In output pixels, origin top-left, on whole pixels so the picture's
  /// edges stay sharp. Zero when either size is empty.
  static func rect(fitting picture: CGSize, in output: CGSize) -> CGRect {
    guard picture.width > 0, picture.height > 0, output.width > 0, output.height > 0 else {
      return .zero
    }
    let scale = min(output.width / picture.width, output.height / picture.height)
    let width = min((picture.width * scale).rounded(), output.width)
    let height = min((picture.height * scale).rounded(), output.height)
    return CGRect(
      x: ((output.width - width) / 2).rounded(.down),
      y: ((output.height - height) / 2).rounded(.down),
      width: width, height: height)
  }
}

/// The picture's place in the output, and the part of it that shows there.
internal struct PictureLayout: Equatable {
  /// Where the picture is drawn, in output pixels from the top-left. With
  /// `.fill` it reaches past the output's edges.
  let picture: CGRect
  /// The part of `picture` inside the output: where subtitles are laid out,
  /// so none is cut off with the picture's edges.
  let visible: CGRect
}

extension PictureFit {
  /// The picture at the shape asked for: as tall as it is, as wide as the
  /// ratio makes it. Nil keeps its own shape.
  static func shape(of picture: CGSize, aspectRatio: Double?) -> CGSize {
    guard let aspectRatio else { return picture }
    return CGSize(width: (picture.height * aspectRatio).rounded(), height: picture.height)
  }

  /// `picture` at the geometry's shape, fitted into `output` or covering it.
  static func layout(picture: CGSize, in output: CGSize, geometry: PictureGeometry) -> PictureLayout {
    let shaped = shape(of: picture, aspectRatio: geometry.aspectRatio)
    guard shaped.width > 0, shaped.height > 0, output.width > 0, output.height > 0 else {
      return PictureLayout(picture: .zero, visible: .zero)
    }
    switch geometry.scaling {
    case .fit:
      let fitted = rect(fitting: shaped, in: output)
      return PictureLayout(picture: fitted, visible: fitted)
    case .fill:
      let scale = max(output.width / shaped.width, output.height / shaped.height)
      let width = (shaped.width * scale).rounded()
      let height = (shaped.height * scale).rounded()
      let picture = CGRect(
        x: ((output.width - width) / 2).rounded(.down),
        y: ((output.height - height) / 2).rounded(.down),
        width: width, height: height)
      return PictureLayout(
        picture: picture, visible: picture.intersection(CGRect(origin: .zero, size: output)))
    }
  }
}
