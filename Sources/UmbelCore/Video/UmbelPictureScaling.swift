/// How the picture fills the view it is shown in.
public enum UmbelPictureScaling: Sendable, Equatable {
  /// All of the picture, black bars where its shape and the view's differ.
  case fit
  /// The whole view, the picture's edges cut off where the shapes differ.
  case fill
}

/// The picture's shape and scaling as the host set them: what a renderer
/// lays each frame out by.
internal struct PictureGeometry: Equatable, Sendable {
  /// Width over height to show the picture at; nil, the source's own.
  var aspectRatio: Double?
  var scaling: UmbelPictureScaling

  static let standard = PictureGeometry(aspectRatio: nil, scaling: .fit)
}
