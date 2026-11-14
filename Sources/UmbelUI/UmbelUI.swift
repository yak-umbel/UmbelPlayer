import UmbelCore

/// UmbelUI's namespace.
///
/// This target provides a ready-made player interface (UIKit, AppKit,
/// SwiftUI). A host with an interface of its own depends on `UmbelCore`
/// alone and need not bring this target in.
public enum UmbelUI {
  public static let version = Umbel.version
}
