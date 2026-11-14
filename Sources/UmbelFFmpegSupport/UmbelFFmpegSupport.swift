import FFmpeg
import Foundation

/// A thin Swift layer over FFmpeg.
///
/// This target bridges the C interface and converts types; it holds no
/// playback logic. The FFmpeg xcframeworks are built by `Tools/BuildFFmpeg`
/// in the LGPL configuration, into `Binaries/`.
public enum UmbelFFmpegSupport {
  /// FFmpeg's own version string, such as `n9.0.2`.
  public static var ffmpegVersion: String? {
    guard let raw = av_version_info() else { return nil }
    return String(cString: raw)
  }

  /// FFmpeg's own license string, such as `LGPL version 2.1 or later`.
  ///
  /// The license as it is at run time. The matching check at build time is
  /// `Tools/verify_ffmpeg_license.sh`; neither replaces the other.
  public static var ffmpegLicense: String? {
    guard let raw = avutil_license() else { return nil }
    return String(cString: raw)
  }

  /// Whether the FFmpeg linked is an LGPL build, fit to ship closed-source.
  public static var isLGPLBuild: Bool {
    guard let license = ffmpegLicense else { return false }
    return licenseIsLGPL(license)
  }

  /// Whether a license string stands for an LGPL build fit to ship
  /// closed-source. An implementation detail, not public.
  ///
  /// The package's floor is macOS 12 / iOS 15, while the standard library's
  /// `String.contains(_: StringProtocol)` needs macOS 13 / iOS 16, hence
  /// Foundation's `range(of:)`.
  private static func licenseIsLGPL(_ license: String) -> Bool {
    let hasLGPL = license.range(of: "LGPL") != nil
    let hasNonfree = license.range(of: "nonfree", options: .caseInsensitive) != nil
    return hasLGPL && !hasNonfree
  }
}
