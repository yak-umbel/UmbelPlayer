import UmbelASSSupport
import UmbelFFmpegSupport

/// UmbelPlayer's namespace and version.
public enum Umbel {
  /// The package version. Semantic versioning: breaking API changes come
  /// only with a major version.
  public static let version = "0.4.0"

  /// The version of the FFmpeg actually loaded, as it says itself, such as
  /// "n9.0.2"; nil if it cannot say. Another copy of FFmpeg in the app
  /// answering here would show as another version.
  public static var ffmpegVersion: String? { UmbelFFmpegSupport.ffmpegVersion }
  /// The license that FFmpeg says it is under: "LGPL version 2.1 or later".
  public static var ffmpegLicense: String? { UmbelFFmpegSupport.ffmpegLicense }
  /// The version of the libass actually loaded, such as "0.17.5".
  public static var libassVersion: String { ASSLibrary.version }
}
