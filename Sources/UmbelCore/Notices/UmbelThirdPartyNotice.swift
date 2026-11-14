import Foundation

/// A bundled library's name, version, license, and upstream license text.
public struct UmbelThirdPartyNotice: Sendable, Equatable {
  public let name: String
  public let version: String
  public let license: String
  public let text: String

  public init(name: String, version: String, license: String, text: String) {
    self.name = name
    self.version = version
    self.license = license
    self.text = text
  }
}

extension Umbel {
  /// License texts for libraries distributed with UmbelPlayer.
  public static var thirdPartyNotices: [UmbelThirdPartyNotice] {
    let entries: [(name: String, version: String, license: String, file: String)] = [
      ("FFmpeg", "n9.0.2", "LGPL-2.1-or-later", "FFmpeg"),
      ("libass", "0.17.5", "ISC", "libass"),
      ("FriBidi", "1.0.17", "LGPL-2.1-or-later", "FriBidi"),
      ("FreeType", "2.14.3", "FTL", "FreeType"),
      ("HarfBuzz", "14.5.0", "MIT", "HarfBuzz"),
      ("dav1d", "1.5.4", "BSD-2-Clause", "dav1d"),
    ]
    return entries.map { entry in
      guard let url = Bundle.module.url(
        forResource: entry.file, withExtension: "txt", subdirectory: "Texts"),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else {
        preconditionFailure("Missing bundled license text for \(entry.name)")
      }
      return UmbelThirdPartyNotice(
        name: entry.name, version: entry.version, license: entry.license, text: text)
    }
  }
}
